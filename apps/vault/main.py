"""vault 서버 (앱·데이터 담당). 서류를 암호화해 저장하고, 조건이 맞을 때만 풀어 준다.

api만 부를 수 있다 (NetworkPolicy + 요청 서명). 화면은 직접 부르지 않는다.
  GET    /healthz
  POST   /documents                  서류 저장 (요청한 사람이 주인) {doc_type, file_name, content_base64}
                                     파일 종류는 내용(앞부분 바이트)으로 판단: PNG, JPEG, WEBP, PDF만 받음
  GET    /documents[?owner_id=...]   서류 목록 (주인, 또는 조건을 갖춘 보호자)
  GET    /documents/{id}             서류 열람 (주인, 또는 조건을 갖춘 보호자)
  DELETE /documents/{id}             서류 삭제 (주인만)

보호자 열람 조건 (rules.access_denied_reason): 보호자 + 비상 상태 + 유효한 열람 토큰
허용과 거부를 모두 audit_logs에 남긴다.
"""
import base64
import binascii
import os
import uuid
from datetime import datetime, timezone

from crypto import DecryptError, decrypt_document, encrypt_document
from internal_auth import HEADER_VIEW_TOKEN, SignatureError, verify
from rules import access_denied_reason
from web import HttpError, JsonHandler, log, make_server, routes

MAX_FILE_BYTES = 5 * 1024 * 1024


def detect_content_type(data):
    """브라우저가 보낸 종류를 믿지 않고 파일 앞부분으로 판단한다.
    (HTML 같은 파일을 그림인 척 올려 열람 화면에서 실행되는 것을 막음)"""
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if data.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    if data.startswith(b"%PDF-"):
        return "application/pdf"
    return None
UUID_RX = r"[0-9a-fA-F-]{36}"


def utcnow():
    return datetime.now(timezone.utc)


def valid_uuid(value):
    try:
        return str(uuid.UUID(str(value))) == str(value).lower()
    except ValueError:
        return False


class VaultApp:
    def __init__(self, store, kms, s3, bucket, kms_key_id, signing_key, now=utcnow):
        self.store, self.kms, self.s3 = store, kms, s3
        self.bucket, self.kms_key_id, self.signing_key = bucket, kms_key_id, signing_key
        self.now = now


class VaultHandler(JsonHandler):
    MAX_BODY = 8 * 1024 * 1024
    ROUTES = routes(
        ("GET", r"/healthz", "healthz"),
        ("POST", r"/documents", "upload"),
        ("GET", r"/documents", "list_docs"),
        ("GET", rf"/documents/(?P<doc_id>{UUID_RX})", "view"),
        ("DELETE", rf"/documents/(?P<doc_id>{UUID_RX})", "delete"),
    )

    def healthz(self):
        return {"status": "ok"}

    def actor(self):
        """api가 서명한 요청인지 확인하고 요청한 사람(users.id)을 돌려준다."""
        if self.app.signing_key is None:
            raise HttpError(503, "signing key not loaded")
        try:
            actor = verify(self.app.signing_key, self.command, self.path, self.headers, self.raw_body())
        except SignatureError as e:
            log("signature_rejected", reason=str(e), client=self.client_address[0])
            raise HttpError(401, "unauthorized") from e
        if not valid_uuid(actor):
            raise HttpError(401, "unauthorized")
        return actor

    def _deny(self, actor, action, reason, document_id=None, status=403):
        self.app.store.audit(actor, action, "denied", reason, document_id)
        log("access_denied", action=action, reason=reason, actor=actor, document_id=document_id)
        raise HttpError(status, reason)

    def _context(self, doc_id, owner_id):
        return {"document_id": doc_id, "owner_id": owner_id}

    # ---------- 저장 ----------

    def upload(self):
        actor = self.actor()
        body = self.json_body()
        doc_type = str(body.get("doc_type") or "").strip()
        file_name = os.path.basename(str(body.get("file_name") or "").replace("\\", "/")).strip()
        if not (1 <= len(doc_type) <= 50):
            raise HttpError(400, "title required (1-50 chars)")
        if not (1 <= len(file_name) <= 255):
            raise HttpError(400, "file_name required (1-255 chars)")
        try:
            content = base64.b64decode(str(body.get("content_base64") or ""), validate=True)
        except (binascii.Error, ValueError):
            raise HttpError(400, "content_base64 invalid") from None
        if not content:
            raise HttpError(400, "empty file")
        if len(content) > MAX_FILE_BYTES:
            raise HttpError(413, "file too large (max 5MB)")
        content_type = detect_content_type(content)
        if content_type is None:
            raise HttpError(415, "only png, jpeg, webp, pdf")

        app = self.app
        doc_id = str(uuid.uuid4())
        s3_key = f"documents/{actor}/{doc_id}"
        blob, encrypted_key = encrypt_document(app.kms, app.kms_key_id, content, self._context(doc_id, actor))
        app.s3.put_object(Bucket=app.bucket, Key=s3_key, Body=blob, ContentType="application/octet-stream")
        try:
            uploaded_at = app.store.insert_document(doc_id, actor, doc_type, file_name, content_type,
                                                    s3_key, encrypted_key)
        except Exception:
            app.s3.delete_object(Bucket=app.bucket, Key=s3_key)  # DB에 못 넣으면 S3에도 남기지 않음
            raise
        app.store.audit(actor, "document_upload", "allowed", None, doc_id)
        return 201, {"id": doc_id, "doc_type": doc_type, "file_name": file_name,
                     "content_type": content_type, "uploaded_at": uploaded_at, "size": len(content)}

    # ---------- 목록 ----------

    def list_docs(self):
        actor = self.actor()
        owner_id = self.query.get("owner_id") or actor
        if not valid_uuid(owner_id):
            raise HttpError(400, "owner_id invalid")
        reason = access_denied_reason(self.app.store, actor, owner_id,
                                      self.headers.get(HEADER_VIEW_TOKEN), self.app.now())
        if reason:
            self._deny(actor, "document_list", reason)
        if actor != owner_id:
            self.app.store.audit(actor, "document_list", "allowed")
        return {"owner_id": owner_id, "documents": self.app.store.list_documents(owner_id)}

    # ---------- 열람 ----------

    def view(self, doc_id):
        actor = self.actor()
        app = self.app
        doc = app.store.get_document(doc_id.lower()) if valid_uuid(doc_id.lower()) else None
        if not doc or doc["deleted_at"]:
            self._deny(actor, "document_view", "not_found", status=404)
        reason = access_denied_reason(app.store, actor, doc["owner_id"],
                                      self.headers.get(HEADER_VIEW_TOKEN), app.now())
        if reason:
            self._deny(actor, "document_view", reason, doc["id"])
        blob = app.s3.get_object(Bucket=app.bucket, Key=doc["s3_key"])["Body"].read()
        try:
            content = decrypt_document(app.kms, app.kms_key_id, blob, doc["encrypted_data_key"],
                                       self._context(doc["id"], doc["owner_id"]))
        except DecryptError as e:
            app.store.audit(actor, "document_view", "denied", "decrypt_failed", doc["id"])
            log("decrypt_failed", document_id=doc["id"], error=str(e))
            raise HttpError(500, "decrypt failed") from e
        app.store.audit(actor, "document_view", "allowed", None, doc["id"])
        return {"id": doc["id"], "owner_id": doc["owner_id"], "doc_type": doc["doc_type"],
                "file_name": doc["file_name"], "content_type": doc["content_type"],
                "uploaded_at": doc["uploaded_at"],
                "content_base64": base64.b64encode(content).decode()}

    # ---------- 삭제 ----------

    def delete(self, doc_id):
        actor = self.actor()
        app = self.app
        doc = app.store.get_document(doc_id.lower()) if valid_uuid(doc_id.lower()) else None
        if not doc or doc["deleted_at"]:
            self._deny(actor, "document_delete", "not_found", status=404)
        if doc["owner_id"] != actor:
            self._deny(actor, "document_delete", "not_owner", doc["id"])
        app.s3.delete_object(Bucket=app.bucket, Key=doc["s3_key"])
        app.store.mark_document_deleted(doc["id"], app.now())
        app.store.audit(actor, "document_delete", "allowed", None, doc["id"])
        return {"deleted": doc["id"]}


def build_app_from_env():
    import boto3

    from db import load_signing_key, make_connect
    from store import PgStore

    env = os.environ
    region = env.get("AWS_REGION", "ap-northeast-2")
    signing_key = None
    try:
        signing_key = load_signing_key(env["APP_SECRET_ARN"], region)
    except Exception as e:  # noqa: BLE001
        log("signing_key_failed", error=type(e).__name__)
    store = PgStore(make_connect(env["DB_HOST"], env.get("DB_NAME", "keeper"), env["DB_SECRET_ARN"], region))
    return VaultApp(store, boto3.client("kms", region_name=region), boto3.client("s3", region_name=region),
                    env["DOC_BUCKET"], env["KMS_KEY_ARN"], signing_key)


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    log("starting", service="vault", port=port)
    make_server(VaultHandler, build_app_from_env(), port).serve_forever()
