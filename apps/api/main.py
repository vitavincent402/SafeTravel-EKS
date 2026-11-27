"""api 서버 (앱·데이터 담당). 화면·문서 담당이 정한 주소 표에 맞춘다.

인증: 모든 /api 요청에 Authorization: Bearer <Cognito 액세스 토큰> (ID 토큰도 받음)
오류: {"error": "..."}  401 로그인 필요 / 403 권한 없음 / 404 없음 / 409 지금 상태에서 불가
시각: UTC ISO (2026-11-24T05:20:00Z)

[공통]
  GET  /api/me                              {id, email, name, role, emergency, emergency_since, emergency_reason}
[여행자]
  GET  /api/docs                            [{id, title, uploaded_at, content_type}]
  POST /api/docs   (multipart: title, file) {id}
  GET  /api/docs/{id}                       파일
  DELETE /api/docs/{id}                     {deleted}                      (추가)
  POST /api/sos                             {emergency: true}
  POST /api/sos/cancel                      {emergency: false}             (추가: 비상 해제)
  GET  /api/requests/pending                {request_id, guardian_name, expires_at} / 없으면 204
  POST /api/requests/{id}/deny              {denied: true}
[보호자]
  GET  /api/guardian/travelers              [{user_id, name, emergency, emergency_since, emergency_reason, request}]
  POST /api/guardian/requests {user_id}     {request_id, wait_until}
  POST /api/guardian/view-token {user_id}   {view_token, expires_at}   (비상 아니면 403)
  GET  /api/guardian/travelers/{user_id}/docs   (X-View-Token)  [{id, title, uploaded_at, content_type}]
  GET  /api/guardian/docs/{id}                  (X-View-Token)  파일
[보호자 관리] (추가)
  GET  /api/guardians                       {my_guardians: [{.., status: pending|accepted}], guarding}
  POST /api/guardians {email}               보호자 초대 → 202 {invited}. 가입 여부와 상관없이 같은 응답
  DELETE /api/guardians/{user_id}           보호자 해제 · 초대 취소
  GET  /api/guardians/invites               받은 보호자 요청(수락 대기) [{id, email, name, invited_at}]
  POST /api/guardians/invites/{owner_id}/accept {agree: true}   수락(열람 조건 동의 필수)
  POST /api/guardians/invites/{owner_id}/decline                거절

서류는 api가 직접 다루지 않는다. 서명한 요청으로 vault에 넘기고, 열람 조건 확인도 vault가 한다.
"""
import base64
import email.parser
import email.policy
import json
import os
import threading
import time
from datetime import datetime, timezone
from urllib.parse import quote

from auth import CognitoVerifier, KeysUnavailable, TokenError
from internal_auth import HEADER_VIEW_TOKEN
from rules import REQUEST_WAIT, VIEW_TOKEN_LIFETIME, emergency_info, new_view_token, settle_requests
from store import AlreadyPending, EmailConflict
from users import LoginRefused, profile_from_claims, user_from_row
from web import HttpError, JsonHandler, RawResponse, log, make_server, routes

UUID = r"[0-9a-fA-F-]{36}"
MAX_FILE_BYTES = 5 * 1024 * 1024  # 서류 최대 크기 (vault와 같은 값)


def utcnow():
    return datetime.now(timezone.utc)


class App:
    """서버가 쓰는 부품 묶음. 시험에서는 가짜 부품을 넣는다."""

    def __init__(self, verifier=None, store=None, vault=None, ensure_ready=None, now=utcnow):
        self.verifier = verifier
        self.store = store
        self.vault = vault
        self.ensure_ready = ensure_ready or (lambda: True)
        self.now = now


def parse_multipart(content_type, body):
    """multipart/form-data → {이름: (파일 이름 또는 None, 바이트)}. 파이썬 기본 email 파서 사용."""
    if not content_type.lower().startswith("multipart/form-data"):
        raise HttpError(400, "multipart/form-data required")
    msg = email.parser.BytesParser(policy=email.policy.HTTP).parsebytes(
        b"Content-Type: " + content_type.encode("latin-1") + b"\r\n\r\n" + body)
    if not msg.is_multipart():
        raise HttpError(400, "invalid multipart body")
    fields = {}
    for part in msg.iter_parts():
        name = part.get_param("name", header="content-disposition")
        if name:
            fields[name] = (part.get_filename(), part.get_payload(decode=True) or b"")
    return fields


def doc_item(d):
    return {"id": d["id"], "title": d["doc_type"], "uploaded_at": d["uploaded_at"],
            "content_type": d.get("content_type")}


class ApiHandler(JsonHandler):
    MAX_BODY = 8 * 1024 * 1024  # 서류 최대 5MB + 여유
    ROUTES = routes(
        ("GET", r"/healthz", "healthz"),
        ("GET", r"/api/healthz", "api_healthz"),
        ("GET", r"/api/me", "me"),
        # 여행자
        ("GET", r"/api/docs", "docs_list"),
        ("POST", r"/api/docs", "docs_upload"),
        ("GET", rf"/api/docs/(?P<doc_id>{UUID})", "docs_view"),
        ("DELETE", rf"/api/docs/(?P<doc_id>{UUID})", "docs_delete"),
        ("POST", r"/api/sos", "sos"),
        ("POST", r"/api/sos/cancel", "sos_cancel"),
        ("GET", r"/api/requests/pending", "requests_pending"),
        ("POST", rf"/api/requests/(?P<request_id>{UUID})/deny", "requests_deny"),
        # 보호자
        ("GET", r"/api/guardian/travelers", "g_travelers"),
        ("POST", r"/api/guardian/requests", "g_request"),
        ("POST", r"/api/guardian/view-token", "g_view_token"),
        ("GET", rf"/api/guardian/travelers/(?P<user_id>{UUID})/docs", "g_docs_list"),
        ("GET", rf"/api/guardian/docs/(?P<doc_id>{UUID})", "g_docs_view"),
        # 보호자 관리
        ("GET", r"/api/guardians", "guardians_list"),
        ("POST", r"/api/guardians", "guardians_add"),
        ("DELETE", rf"/api/guardians/(?P<guardian_id>{UUID})", "guardians_remove"),
        ("GET", r"/api/guardians/invites", "invites_list"),
        ("POST", rf"/api/guardians/invites/(?P<owner_id>{UUID})/accept", "invites_accept"),
        ("POST", rf"/api/guardians/invites/(?P<owner_id>{UUID})/decline", "invites_decline"),
    )

    # ---------- 로그인 ----------

    def current_user(self):
        """토큰을 확인하고 users 행을 찾거나 만든다. 실패하면 HttpError."""
        app = self.app
        if app.verifier is None:
            raise HttpError(503, "login not configured")
        scheme, _, token = (self.headers.get("Authorization") or "").partition(" ")
        token = token.strip()
        if scheme.lower() != "bearer" or not token:
            self._auth_failed("Authorization 헤더 없음")
        try:
            claims = app.verifier.verify(token)
        except TokenError as e:
            self._auth_failed(str(e))
        except KeysUnavailable as e:
            log("jwks_unavailable", error=str(e))
            raise HttpError(503, "login temporarily unavailable") from e
        if app.store is None or not app.ensure_ready():
            raise HttpError(503, "database not ready")
        try:
            if claims["token_use"] == "access":
                row = app.store.user_by_sub(claims["sub"])
                if row is None:  # 처음 로그인: 액세스 토큰에는 이메일이 없어 Cognito에 한 번 물어봄
                    try:
                        info = app.verifier.userinfo(token)
                    except KeysUnavailable as e:
                        log("userinfo_failed", error=str(e))
                        raise HttpError(503, "login temporarily unavailable") from e
                    if info.get("sub") != claims["sub"]:
                        self._auth_failed("userInfo sub 불일치")
                    row = app.store.login(*profile_from_claims(info))
            else:
                row = app.store.login(*profile_from_claims(claims))
        except LoginRefused as e:
            log("login_refused", reason=str(e), sub=claims.get("sub"))
            raise HttpError(403, "forbidden") from e
        except EmailConflict as e:
            log("email_conflict", sub=claims.get("sub"))
            raise HttpError(409, "email already used by another account") from e
        return user_from_row(row)

    def _auth_failed(self, reason):
        log("auth_failed", path=self.path_only, reason=reason, client=self.client_address[0])
        raise HttpError(401, "login required", {"WWW-Authenticate": "Bearer"})

    # ---------- 공통 도우미 ----------

    def require_guardian_of(self, user, owner_id, action):
        if not isinstance(owner_id, str) or len(owner_id) != 36:
            raise HttpError(400, "user_id required")
        if not self.app.store.is_guardian(owner_id, user.id):
            self.app.store.audit(user.id, action, "denied", "not_guardian")
            raise HttpError(403, "not_guardian")

    def vault_json(self, method, path, user, body=None, view_token=None):
        if self.app.vault is None:
            raise HttpError(503, "vault not configured")
        status, data = self.app.vault.call(method, path, user.id, body, view_token)
        if status >= 400:
            raise HttpError(status, data.get("error", "vault error"))
        return status, data

    def vault_file(self, doc_id, user, view_token=None):
        _, data = self.vault_json("GET", f"/documents/{doc_id}", user, view_token=view_token)
        disposition = "inline; filename*=UTF-8''" + quote(data["file_name"])
        return RawResponse(200, base64.b64decode(data["content_base64"]), data["content_type"], {
            "Content-Disposition": disposition,
            "Content-Security-Policy": "default-src 'none'; img-src 'self'; sandbox",
        })

    def view_token_header(self):
        return self.headers.get(HEADER_VIEW_TOKEN) or None

    # ---------- 상태 확인 ----------

    def healthz(self):
        return {"status": "ok"}

    def api_healthz(self):
        return {"api": "ok", "vault": self.app.vault.health() if self.app.vault else {"error": "not configured"}}

    # ---------- 공통 ----------

    def me(self):
        user = self.current_user()
        settle_requests(self.app.store, user.id, self.app.now())
        return {**user.to_dict(), **emergency_info(self.app.store, user.id)}

    # ---------- 여행자 ----------

    def docs_list(self):
        user = self.current_user()
        _, data = self.vault_json("GET", "/documents", user)
        return [doc_item(d) for d in data["documents"]]

    def docs_upload(self):
        user = self.current_user()
        try:
            fields = parse_multipart(self.headers.get("Content-Type") or "", self.raw_body())
        except HttpError as e:
            # 11-25 업로드 첫 시도 400 원인 추적용. 본문 내용은 남기지 않고 모양만 기록한다.
            body = self.raw_body()
            log("upload_parse_failed", error=e.error, content_length=self.headers.get("Content-Length"),
                transfer_encoding=self.headers.get("Transfer-Encoding"), body_bytes=len(body),
                starts_with_boundary=body.lstrip(b"\r\n").startswith(b"--"),
                conn_request_no=getattr(self, "conn_request_no", None))
            raise
        title = (fields.get("title") or (None, b""))[1].decode("utf-8", "replace").strip()
        filename, content = fields.get("file") or (None, b"")
        # 수정 확인용: 성공한 업로드도 연결 내 몇 번째 요청이었는지와 크기를 남긴다(내용·제목·사용자 정보는 남기지 않음).
        log("upload_parsed", content_length=self.headers.get("Content-Length"),
            body_bytes=len(self.raw_body()), file_bytes=len(content),
            conn_request_no=getattr(self, "conn_request_no", None))
        if not content:
            raise HttpError(400, "file required")
        # vault 한도(5MB)와 같게 여기서 먼저 막는다. 넘기면 base64로 커져 vault 본문 한도(8MB)를 넘고 503이 났음(11-27)
        if len(content) > MAX_FILE_BYTES:
            raise HttpError(413, "file too large (max 5MB)")
        status, data = self.vault_json("POST", "/documents", user, body={
            "doc_type": title, "file_name": filename or "file",
            "content_base64": base64.b64encode(content).decode()})
        return status, {"id": data["id"]}

    def docs_view(self, doc_id):
        return self.vault_file(doc_id, self.current_user())

    def docs_delete(self, doc_id):
        _, data = self.vault_json("DELETE", f"/documents/{doc_id}", self.current_user())
        return data

    def sos(self):
        user = self.current_user()
        store, now = self.app.store, self.app.now()
        settle_requests(store, user.id, now)
        if emergency_info(store, user.id)["emergency"]:
            raise HttpError(409, "already_emergency")
        store.set_emergency(user.id, "emergency", "sos", now)
        store.cancel_requests(user.id, now)  # 대기 중 요청은 의미가 없어짐
        store.audit(user.id, "emergency_sos", "allowed")
        return {"emergency": True}

    def sos_cancel(self):
        user = self.current_user()
        store, now = self.app.store, self.app.now()
        settle_requests(store, user.id, now)
        if not emergency_info(store, user.id)["emergency"]:
            raise HttpError(409, "not_emergency")
        store.set_emergency(user.id, "normal", None, now)
        store.cancel_requests(user.id, now)
        revoked = store.revoke_view_tokens(user.id, now)
        store.audit(user.id, "emergency_clear", "allowed")
        return {"emergency": False, "revoked_tokens": revoked}

    def requests_pending(self):
        user = self.current_user()
        store, now = self.app.store, self.app.now()
        settle_requests(store, user.id, now)
        pending = store.pending_request(user.id, now)
        return pending if pending else RawResponse(204)

    def requests_deny(self, request_id):
        user = self.current_user()
        store, now = self.app.store, self.app.now()
        req = store.get_request(request_id)
        if not req or req["owner_id"] != user.id:
            raise HttpError(404, "not found")
        settle_requests(store, user.id, now)
        if not store.deny_request(request_id, user.id, now):
            raise HttpError(409, "not_pending")
        store.audit(user.id, "request_deny", "allowed")
        return {"denied": True}

    # ---------- 보호자 ----------

    def g_travelers(self):
        user = self.current_user()
        store, now = self.app.store, self.app.now()
        out = []
        for o in store.guarding(user.id):
            settle_requests(store, o["id"], now)
            out.append({"user_id": o["id"], "name": o["name"], **emergency_info(store, o["id"]),
                        "request": store.latest_request(o["id"], user.id)})
        return out

    def g_request(self):
        user = self.current_user()
        owner_id = self.json_body().get("user_id")
        self.require_guardian_of(user, owner_id, "request_create")
        store, now = self.app.store, self.app.now()
        settle_requests(store, owner_id, now)
        if emergency_info(store, owner_id)["emergency"]:
            raise HttpError(409, "already_emergency")
        try:
            req = store.create_request(owner_id, user.id, now + REQUEST_WAIT)
        except AlreadyPending:
            raise HttpError(409, "already_pending") from None
        store.audit(user.id, "request_create", "allowed")
        return 201, req

    def g_view_token(self):
        user = self.current_user()
        owner_id = self.json_body().get("user_id")
        self.require_guardian_of(user, owner_id, "view_token_issue")
        store, now = self.app.store, self.app.now()
        settle_requests(store, owner_id, now)
        if not emergency_info(store, owner_id)["emergency"]:
            store.audit(user.id, "view_token_issue", "denied", "not_emergency")
            raise HttpError(403, "not_emergency")
        token, token_hash = new_view_token()
        expires_at = now + VIEW_TOKEN_LIFETIME
        store.insert_view_token(token_hash, user.id, owner_id, expires_at)
        store.audit(user.id, "view_token_issue", "allowed")
        return 201, {"view_token": token, "expires_at": expires_at}

    def g_docs_list(self, user_id):
        user = self.current_user()
        _, data = self.vault_json("GET", f"/documents?owner_id={user_id.lower()}", user,
                                  view_token=self.view_token_header())
        return [doc_item(d) for d in data["documents"]]

    def g_docs_view(self, doc_id):
        return self.vault_file(doc_id, self.current_user(), self.view_token_header())

    # ---------- 보호자 관리 ----------

    def guardians_list(self):
        user = self.current_user()
        return {"my_guardians": self.app.store.my_guardians(user.id),
                "guarding": self.app.store.guarding(user.id)}

    def guardians_add(self):
        user = self.current_user()
        target_email = str(self.json_body().get("email") or "").strip().lower()
        store = self.app.store
        if not target_email:
            raise HttpError(400, "email required")
        if target_email == user.email.lower():
            raise HttpError(400, "cannot add yourself")
        # 초대만 한다. 보호자가 수락해야 열람 조건에 들어간다.
        # 가입하지 않은 이메일이어도 같은 응답을 돌려줘 가입 여부를 알 수 없게 한다.
        target = store.user_by_email(target_email)
        if target is None:
            store.audit(user.id, "guardian_invite", "denied", "guardian_not_found")
        elif store.add_guardian(user.id, target["id"]):
            store.audit(user.id, "guardian_invite", "allowed")
        return 202, {"invited": target_email}

    def invites_list(self):
        return self.app.store.invites(self.current_user().id)

    def invites_accept(self, owner_id):
        user = self.current_user()
        if self.json_body().get("agree") is not True:
            raise HttpError(400, "agree_required")
        if not self.app.store.accept_invite(owner_id.lower(), user.id):
            raise HttpError(404, "invite_not_found")
        self.app.store.audit(user.id, "guardian_accept", "allowed")
        return {"accepted": owner_id}

    def invites_decline(self, owner_id):
        user = self.current_user()
        if not self.app.store.decline_invite(owner_id.lower(), user.id):
            raise HttpError(404, "invite_not_found")
        self.app.store.audit(user.id, "guardian_decline", "allowed")
        return {"declined": owner_id}

    def guardians_remove(self, guardian_id):
        user = self.current_user()
        if not self.app.store.remove_guardian(user.id, guardian_id.lower()):
            raise HttpError(404, "not found")
        self.app.store.audit(user.id, "guardian_remove", "allowed")
        return {"removed": guardian_id}


# ---------- 실행 ----------

def build_app_from_env():
    env = os.environ
    region = env.get("AWS_REGION", "ap-northeast-2")

    verifier = None
    if env.get("COGNITO_USER_POOL_ID") and env.get("COGNITO_CLIENT_ID"):
        verifier = CognitoVerifier(region, env["COGNITO_USER_POOL_ID"], env["COGNITO_CLIENT_ID"])
    else:
        log("config_missing", missing="COGNITO_USER_POOL_ID/COGNITO_CLIENT_ID")

    vault = None
    if env.get("APP_SECRET_ARN"):
        from db import load_signing_key
        from vault_client import VaultClient
        try:
            vault = VaultClient(env.get("VAULT_URL", "http://keeper-vault:8080"),
                                load_signing_key(env["APP_SECRET_ARN"], region))
        except Exception as e:  # noqa: BLE001
            log("signing_key_failed", error=type(e).__name__)
    else:
        log("config_missing", missing="APP_SECRET_ARN")

    store, ensure_ready = None, None
    if env.get("DB_HOST") and env.get("DB_SECRET_ARN"):
        from db import apply_schema, make_connect, missing_tables
        from store import PgStore

        connect = make_connect(env["DB_HOST"], env.get("DB_NAME", "keeper"), env["DB_SECRET_ARN"], region)
        store = PgStore(connect)
        state = {"ready": False, "last_try": 0.0}
        lock = threading.Lock()
        # SCHEMA_APPLY=off: table은 따로(keeper_migrate Job) 만들고, api는 있는지만 확인한다.
        # 값이 없으면 지금처럼 api가 직접 만든다 (계정 분리 전과 같은 동작).
        apply = env.get("SCHEMA_APPLY", "on").lower() != "off"

        def ensure_ready():
            """table이 준비되었는지 확인. 안 되어 있으면 만들어 본다 (10초에 한 번까지)."""
            if state["ready"]:
                return True
            with lock:
                if state["ready"] or time.monotonic() - state["last_try"] < 10:
                    return state["ready"]
                state["last_try"] = time.monotonic()
                try:
                    if apply:
                        apply_schema(connect)
                    else:
                        missing = missing_tables(connect)
                        if missing:
                            log("schema_missing", tables=",".join(missing))
                            return False
                    if env.get("SEED_JSON"):
                        store.seed(json.loads(env["SEED_JSON"]))
                    state["ready"] = True
                    log("schema_ready")
                except Exception as e:  # noqa: BLE001
                    log("schema_failed", error=type(e).__name__)
            return state["ready"]

        threading.Thread(target=ensure_ready, daemon=True).start()
    else:
        log("config_missing", missing="DB_HOST/DB_SECRET_ARN")

    return App(verifier, store, vault, ensure_ready)


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    log("starting", service="api", port=port)
    make_server(ApiHandler, build_app_from_env(), port).serve_forever()
