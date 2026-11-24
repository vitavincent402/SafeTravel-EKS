"""api 서버 (앱·데이터 담당).

주소
  GET /healthz        파드 상태 확인 (쿠버네티스가 씀)
  GET /api/healthz    api → vault 연결 확인
  GET /api/me         로그인한 사람 정보 {id, email, name, role}
                      화면은 role(user/guardian)을 보고 화면을 나눈다.

로그인 확인은 auth.py, 사용자 table 연결은 users.py, DB 연결은 db.py.
웹 프레임워크는 아직 정하지 않아서 파이썬 기본 서버를 그대로 쓴다 (나중에 바꿔도 위 파일은 그대로 씀).
"""
import json
import os
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from auth import CognitoVerifier, KeysUnavailable, TokenError
from users import EmailConflict, LoginRefused, profile_from_claims


def log(event, **fields):
    """한 줄 JSON 로그. 토큰 값이나 비밀번호는 절대 넣지 않는다."""
    print(json.dumps({"event": event, **fields}, ensure_ascii=False), file=sys.stdout, flush=True)


class App:
    """서버가 쓰는 부품 묶음. 시험에서는 가짜 부품을 넣는다."""

    def __init__(self, verifier=None, store=None, vault_url="", ensure_ready=None):
        self.verifier = verifier
        self.store = store
        self.vault_url = vault_url
        self.ensure_ready = ensure_ready or (lambda: True)


class Handler(BaseHTTPRequestHandler):
    server_version = "keeper-api"
    sys_version = ""

    @property
    def app(self):
        return self.server.app

    def _send(self, code, body, headers=None):
        data = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def _bearer_token(self):
        value = self.headers.get("Authorization", "")
        scheme, _, token = value.partition(" ")
        if scheme.lower() != "bearer" or not token.strip():
            return None
        return token.strip()

    def _unauthorized(self, reason):
        log("auth_failed", path=self.path, reason=reason, client=self.client_address[0])
        self._send(401, {"error": "unauthorized"}, {"WWW-Authenticate": "Bearer"})

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/healthz":
            return self._send(200, {"status": "ok"})
        if path == "/api/healthz":
            return self._vault_health()
        if path == "/api/me":
            return self._me()
        return self._send(404, {"error": "not found"})

    def _vault_health(self):
        try:
            with urllib.request.urlopen(f"{self.app.vault_url}/healthz", timeout=3) as r:
                vault = json.load(r)
        except Exception as e:  # noqa: BLE001
            vault = {"error": str(e)}
        return self._send(200, {"api": "ok", "vault": vault})

    def _me(self):
        if self.app.verifier is None:
            return self._send(503, {"error": "login not configured"})
        token = self._bearer_token()
        if token is None:
            return self._unauthorized("Authorization 헤더 없음")
        try:
            claims = self.app.verifier.verify(token)
        except TokenError as e:
            return self._unauthorized(str(e))
        except KeysUnavailable as e:
            log("jwks_unavailable", error=str(e))
            return self._send(503, {"error": "login temporarily unavailable"})
        try:
            sub, email, name = profile_from_claims(claims)
        except LoginRefused as e:
            log("login_refused", reason=str(e), sub=claims.get("sub"))
            return self._send(403, {"error": "forbidden"})
        if self.app.store is None or not self.app.ensure_ready():
            return self._send(503, {"error": "database not ready"})
        try:
            user = self.app.store.login(sub, email, name)
        except EmailConflict:
            log("email_conflict", sub=sub)
            return self._send(409, {"error": "email already used by another account"})
        except Exception as e:  # noqa: BLE001
            log("db_error", error=type(e).__name__)
            return self._send(503, {"error": "database error"})
        return self._send(200, user.to_dict())

    def log_message(self, *args):
        pass


def make_server(app, port, host="0.0.0.0"):
    server = ThreadingHTTPServer((host, port), Handler)
    server.daemon_threads = True
    server.app = app
    return server


def build_app_from_env():
    env = os.environ
    region = env.get("AWS_REGION", "ap-northeast-2")

    verifier = None
    if env.get("COGNITO_USER_POOL_ID") and env.get("COGNITO_CLIENT_ID"):
        verifier = CognitoVerifier(region, env["COGNITO_USER_POOL_ID"], env["COGNITO_CLIENT_ID"])
    else:
        log("config_missing", missing="COGNITO_USER_POOL_ID/COGNITO_CLIENT_ID")

    store, ensure_ready = None, None
    if env.get("DB_HOST") and env.get("DB_SECRET_ARN"):
        from db import apply_schema, make_connect
        from users import PostgresUserStore

        connect = make_connect(env["DB_HOST"], env.get("DB_NAME", "keeper"), env["DB_SECRET_ARN"], region)
        store = PostgresUserStore(connect)
        state = {"ready": False, "last_try": 0.0}
        lock = threading.Lock()

        def ensure_ready():
            """table이 준비되었는지 확인. 안 되어 있으면 만들어 본다 (10초에 한 번까지)."""
            if state["ready"]:
                return True
            with lock:
                if state["ready"] or time.monotonic() - state["last_try"] < 10:
                    return state["ready"]
                state["last_try"] = time.monotonic()
                try:
                    apply_schema(connect)
                    state["ready"] = True
                    log("schema_ready")
                except Exception as e:  # noqa: BLE001
                    log("schema_failed", error=type(e).__name__)
            return state["ready"]

        threading.Thread(target=ensure_ready, daemon=True).start()  # 켜질 때 미리 시도
    else:
        log("config_missing", missing="DB_HOST/DB_SECRET_ARN")

    return App(verifier, store, env.get("VAULT_URL", "http://keeper-vault:8080"), ensure_ready)


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    log("starting", port=port)
    make_server(build_app_from_env(), port).serve_forever()
