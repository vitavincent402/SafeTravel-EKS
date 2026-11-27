"""DB 읽기·쓰기 모음 (api와 vault에 같은 파일이 있음).

PgStore     실제 PostgreSQL (SQL은 모두 여기에 모아 둠)
MemoryStore 시험용 가짜 저장소 (같은 이름의 함수를 dict로 흉내 냄)
"""
import threading
import uuid
from datetime import datetime, timezone

from db import PgBase


class EmailConflict(Exception):
    """같은 이메일을 다른 Cognito 계정이 이미 씀."""


class AlreadyPending(Exception):
    """이 여행자에게 이미 대기 중인 열람 요청이 있음."""


_IS_GUARDIAN = "EXISTS (SELECT 1 FROM guardians g WHERE g.guardian_id = users.id AND g.status = 'accepted') AS is_guardian"

SQL = {
    # ---- 사용자 ----
    "login": f"""
        INSERT INTO users (email, name, cognito_sub) VALUES (%s, %s, %s)
        ON CONFLICT (cognito_sub) DO UPDATE SET email = EXCLUDED.email, name = EXCLUDED.name
        RETURNING id::text AS id, email, name, {_IS_GUARDIAN}""",
    "user_by_sub": f"SELECT id::text AS id, email, name, {_IS_GUARDIAN} FROM users WHERE cognito_sub = %s",
    "user_by_email": "SELECT id::text AS id, email, name FROM users WHERE email = %s",
    # ---- 보호자 ----
    "add_guardian": """
        INSERT INTO guardians (owner_id, guardian_id) VALUES (%s, %s)
        ON CONFLICT (owner_id, guardian_id) DO NOTHING RETURNING id::text AS id""",
    "remove_guardian": "DELETE FROM guardians WHERE owner_id = %s AND guardian_id = %s",
    "my_guardians": """
        SELECT u.id::text AS id, u.email, u.name, g.status FROM guardians g JOIN users u ON u.id = g.guardian_id
        WHERE g.owner_id = %s ORDER BY g.created_at""",
    # 보호자로서 지키는 사람: 수락한 관계만
    "guarding": """
        SELECT u.id::text AS id, u.email, u.name FROM guardians g JOIN users u ON u.id = g.owner_id
        WHERE g.guardian_id = %s AND g.status = 'accepted' ORDER BY g.created_at""",
    # 열람 조건(api·vault 공통): 수락한 보호자만
    "is_guardian": """
        SELECT EXISTS (SELECT 1 FROM guardians WHERE owner_id = %s AND guardian_id = %s
                       AND status = 'accepted') AS ok""",
    # 받은 보호자 요청(수락 대기)
    "invites": """
        SELECT u.id::text AS id, u.email, u.name, g.created_at AS invited_at FROM guardians g
        JOIN users u ON u.id = g.owner_id WHERE g.guardian_id = %s AND g.status = 'pending' ORDER BY g.created_at""",
    "accept_invite": """
        UPDATE guardians SET status = 'accepted', accepted_at = now()
        WHERE owner_id = %s AND guardian_id = %s AND status = 'pending' RETURNING id::text AS id""",
    "decline_invite": "DELETE FROM guardians WHERE owner_id = %s AND guardian_id = %s AND status = 'pending'",
    # ---- 비상 상태 ----
    "get_emergency": "SELECT status, trigger_source, changed_at FROM emergency_states WHERE user_id = %s",
    "set_emergency": """
        INSERT INTO emergency_states (user_id, status, trigger_source, changed_at) VALUES (%s, %s, %s, %s)
        ON CONFLICT (user_id) DO UPDATE SET status = EXCLUDED.status,
            trigger_source = EXCLUDED.trigger_source, changed_at = EXCLUDED.changed_at""",
    # ---- 열람 요청 ----
    "create_request": """
        INSERT INTO access_requests (owner_id, guardian_id, wait_until) VALUES (%s, %s, %s)
        RETURNING id::text AS request_id, wait_until""",
    "pending_request": """
        SELECT r.id::text AS request_id, u.name AS guardian_name, r.wait_until AS expires_at
        FROM access_requests r JOIN users u ON u.id = r.guardian_id
        WHERE r.owner_id = %s AND r.status = 'pending' AND r.wait_until > %s
        ORDER BY r.requested_at DESC LIMIT 1""",
    "get_request": """
        SELECT id::text AS id, owner_id::text AS owner_id, status, wait_until FROM access_requests WHERE id = %s""",
    "deny_request": """
        UPDATE access_requests SET status = 'denied', responded_at = %s
        WHERE id = %s AND owner_id = %s AND status = 'pending' AND wait_until > %s""",
    "expire_requests": """
        UPDATE access_requests SET status = 'timeout'
        WHERE owner_id = %s AND status = 'pending' AND wait_until <= %s RETURNING wait_until""",
    "cancel_requests": """
        UPDATE access_requests SET status = 'cancelled', responded_at = %s
        WHERE owner_id = %s AND status = 'pending'""",
    "latest_request": """
        SELECT id::text AS request_id, status, wait_until FROM access_requests
        WHERE owner_id = %s AND guardian_id = %s ORDER BY requested_at DESC LIMIT 1""",
    # ---- 열람 토큰 ----
    "insert_view_token": """
        INSERT INTO view_tokens (token_hash, guardian_id, owner_id, expires_at) VALUES (%s, %s, %s, %s)""",
    "revoke_view_tokens": "UPDATE view_tokens SET revoked_at = %s WHERE owner_id = %s AND revoked_at IS NULL",
    "valid_view_token": """
        SELECT EXISTS (SELECT 1 FROM view_tokens WHERE token_hash = %s AND guardian_id = %s
            AND owner_id = %s AND revoked_at IS NULL AND expires_at > %s) AS ok""",
    # ---- 서류 ----
    "insert_document": """
        INSERT INTO documents (id, owner_id, doc_type, file_name, content_type, s3_key, encrypted_data_key)
        VALUES (%s, %s, %s, %s, %s, %s, %s) RETURNING uploaded_at""",
    "get_document": """
        SELECT id::text AS id, owner_id::text AS owner_id, doc_type, file_name, content_type, s3_key,
               encrypted_data_key, uploaded_at, deleted_at FROM documents WHERE id = %s""",
    "list_documents": """
        SELECT id::text AS id, doc_type, file_name, content_type, uploaded_at FROM documents
        WHERE owner_id = %s AND deleted_at IS NULL ORDER BY uploaded_at DESC""",
    "mark_document_deleted": """
        UPDATE documents SET deleted_at = %s, encrypted_data_key = %s WHERE id = %s AND deleted_at IS NULL""",
    # ---- 감사 ----
    "audit": """
        INSERT INTO audit_logs (actor_id, document_id, action, result, deny_reason) VALUES (%s, %s, %s, %s, %s)""",
    # ---- 시험 데이터 ----
    "seed_user": "INSERT INTO users (email, name, cognito_sub) VALUES (%s, %s, %s) ON CONFLICT DO NOTHING",
    "seed_guardian": """
        INSERT INTO guardians (owner_id, guardian_id, status, accepted_at)
        SELECT o.id, g.id, 'accepted', now() FROM users o, users g WHERE o.email = %s AND g.email = %s
        ON CONFLICT DO NOTHING""",
}


class PgStore(PgBase):
    def login(self, sub, email, name):
        try:
            return self._one(SQL["login"], (email, name, sub))
        except Exception as e:
            if getattr(e, "sqlstate", None) == "23505":
                raise EmailConflict(email) from e
            raise

    def user_by_sub(self, sub):
        return self._one(SQL["user_by_sub"], (sub,))

    def user_by_email(self, email):
        return self._one(SQL["user_by_email"], (email,))

    def add_guardian(self, owner_id, guardian_id):
        return self._one(SQL["add_guardian"], (owner_id, guardian_id)) is not None

    def remove_guardian(self, owner_id, guardian_id):
        return self._exec(SQL["remove_guardian"], (owner_id, guardian_id)) > 0

    def my_guardians(self, owner_id):
        return self._rows(SQL["my_guardians"], (owner_id,))

    def guarding(self, guardian_id):
        return self._rows(SQL["guarding"], (guardian_id,))

    def is_guardian(self, owner_id, guardian_id):
        return bool(self._value(SQL["is_guardian"], (owner_id, guardian_id)))

    def invites(self, guardian_id):
        return self._rows(SQL["invites"], (guardian_id,))

    def accept_invite(self, owner_id, guardian_id):
        return self._one(SQL["accept_invite"], (owner_id, guardian_id)) is not None

    def decline_invite(self, owner_id, guardian_id):
        return self._exec(SQL["decline_invite"], (owner_id, guardian_id)) > 0

    def get_emergency(self, user_id):
        return self._one(SQL["get_emergency"], (user_id,))

    def set_emergency(self, user_id, status, trigger_source, changed_at):
        self._exec(SQL["set_emergency"], (user_id, status, trigger_source, changed_at))

    def create_request(self, owner_id, guardian_id, wait_until):
        try:
            return self._one(SQL["create_request"], (owner_id, guardian_id, wait_until))
        except Exception as e:
            if getattr(e, "sqlstate", None) == "23505":  # 대기 중 요청은 하나만 (uq_access_requests_one_pending)
                raise AlreadyPending(owner_id) from e
            raise

    def pending_request(self, owner_id, now):
        return self._one(SQL["pending_request"], (owner_id, now))

    def get_request(self, request_id):
        return self._one(SQL["get_request"], (request_id,))

    def deny_request(self, request_id, owner_id, now):
        return self._exec(SQL["deny_request"], (now, request_id, owner_id, now)) > 0

    def expire_requests(self, owner_id, now):
        return [r["wait_until"] for r in self._rows(SQL["expire_requests"], (owner_id, now))]

    def cancel_requests(self, owner_id, now):
        return self._exec(SQL["cancel_requests"], (now, owner_id))

    def latest_request(self, owner_id, guardian_id):
        return self._one(SQL["latest_request"], (owner_id, guardian_id))

    def insert_view_token(self, token_hash, guardian_id, owner_id, expires_at):
        self._exec(SQL["insert_view_token"], (token_hash, guardian_id, owner_id, expires_at))

    def revoke_view_tokens(self, owner_id, now):
        return self._exec(SQL["revoke_view_tokens"], (now, owner_id))

    def valid_view_token(self, token_hash, guardian_id, owner_id, now):
        return bool(self._value(SQL["valid_view_token"], (token_hash, guardian_id, owner_id, now)))

    def insert_document(self, doc_id, owner_id, doc_type, file_name, content_type, s3_key, encrypted_data_key):
        return self._value(SQL["insert_document"],
                           (doc_id, owner_id, doc_type, file_name, content_type, s3_key, encrypted_data_key))

    def get_document(self, doc_id):
        row = self._one(SQL["get_document"], (doc_id,))
        if row:
            row["encrypted_data_key"] = bytes(row["encrypted_data_key"])
        return row

    def list_documents(self, owner_id):
        return self._rows(SQL["list_documents"], (owner_id,))

    def mark_document_deleted(self, doc_id, now):
        # 암호화된 데이터 키를 비워서, 혹시 S3에 사본이 남아도 다시 풀 수 없게 한다
        return self._exec(SQL["mark_document_deleted"], (now, b"", doc_id)) > 0

    def audit(self, actor_id, action, result, deny_reason=None, document_id=None):
        self._exec(SQL["audit"], (actor_id, document_id, action, result, deny_reason))

    def seed(self, data):
        """시험 데이터: {"users": [{email, name, cognito_sub}], "guardians": [{owner_email, guardian_email}]}"""
        for u in data.get("users", []):
            self._exec(SQL["seed_user"], (u["email"].lower(), u["name"], u["cognito_sub"]))
        for g in data.get("guardians", []):
            self._exec(SQL["seed_guardian"], (g["owner_email"].lower(), g["guardian_email"].lower()))


class MemoryStore:
    """시험용. PgStore와 같은 함수, 같은 결과 모양."""

    def __init__(self):
        self.lock = threading.RLock()
        self.users = {}        # id -> {id, email, name, sub}
        self.guardians = []    # (owner_id, guardian_id) 순서 유지
        self.gstatus = {}      # (owner_id, guardian_id) -> pending | accepted
        self.emergency = {}    # user_id -> {status, trigger_source, changed_at}
        self.requests = []     # dicts (만든 순서)
        self.tokens = []
        self.documents = {}
        self.audits = []

    def _with_role(self, u):
        return {"id": u["id"], "email": u["email"], "name": u["name"],
                "is_guardian": any(g == u["id"] and self.gstatus[(o, g)] == "accepted" for o, g in self.guardians)}

    def _pub(self, u):
        return {"id": u["id"], "email": u["email"], "name": u["name"]}

    def login(self, sub, email, name):
        with self.lock:
            if any(u["email"] == email and u["sub"] != sub for u in self.users.values()):
                raise EmailConflict(email)
            user = next((u for u in self.users.values() if u["sub"] == sub), None)
            if user is None:
                uid = str(uuid.uuid4())
                user = self.users[uid] = {"id": uid, "sub": sub}
            user.update(email=email, name=name)
            return self._with_role(user)

    def user_by_sub(self, sub):
        u = next((u for u in self.users.values() if u["sub"] == sub), None)
        return self._with_role(u) if u else None

    def user_by_email(self, email):
        u = next((u for u in self.users.values() if u["email"] == email), None)
        return self._pub(u) if u else None

    def add_guardian(self, owner_id, guardian_id):
        if owner_id == guardian_id:
            raise ValueError("CHECK owner_id <> guardian_id")
        if (owner_id, guardian_id) in self.guardians:
            return False
        self.guardians.append((owner_id, guardian_id))
        self.gstatus[(owner_id, guardian_id)] = "pending"
        return True

    def remove_guardian(self, owner_id, guardian_id):
        if (owner_id, guardian_id) not in self.guardians:
            return False
        self.guardians.remove((owner_id, guardian_id))
        self.gstatus.pop((owner_id, guardian_id), None)
        return True

    def my_guardians(self, owner_id):
        return [{**self._pub(self.users[g]), "status": self.gstatus[(o, g)]} for o, g in self.guardians if o == owner_id]

    def guarding(self, guardian_id):
        return [self._pub(self.users[o]) for o, g in self.guardians
                if g == guardian_id and self.gstatus[(o, g)] == "accepted"]

    def is_guardian(self, owner_id, guardian_id):
        return self.gstatus.get((owner_id, guardian_id)) == "accepted"

    def invites(self, guardian_id):
        return [{**self._pub(self.users[o]), "invited_at": None} for o, g in self.guardians
                if g == guardian_id and self.gstatus[(o, g)] == "pending"]

    def accept_invite(self, owner_id, guardian_id):
        if self.gstatus.get((owner_id, guardian_id)) != "pending":
            return False
        self.gstatus[(owner_id, guardian_id)] = "accepted"
        return True

    def decline_invite(self, owner_id, guardian_id):
        if self.gstatus.get((owner_id, guardian_id)) != "pending":
            return False
        return self.remove_guardian(owner_id, guardian_id)

    def get_emergency(self, user_id):
        s = self.emergency.get(user_id)
        return dict(s) if s else None

    def set_emergency(self, user_id, status, trigger_source, changed_at):
        self.emergency[user_id] = {"status": status, "trigger_source": trigger_source, "changed_at": changed_at}

    def create_request(self, owner_id, guardian_id, wait_until):
        with self.lock:
            if any(r["owner_id"] == owner_id and r["status"] == "pending" for r in self.requests):
                raise AlreadyPending(owner_id)
            r = {"id": str(uuid.uuid4()), "owner_id": owner_id, "guardian_id": guardian_id,
                 "status": "pending", "wait_until": wait_until, "seq": len(self.requests)}
            self.requests.append(r)
            return {"request_id": r["id"], "wait_until": wait_until}

    def pending_request(self, owner_id, now):
        for r in reversed(self.requests):
            if r["owner_id"] == owner_id and r["status"] == "pending" and r["wait_until"] > now:
                return {"request_id": r["id"], "guardian_name": self.users[r["guardian_id"]]["name"],
                        "expires_at": r["wait_until"]}
        return None

    def get_request(self, request_id):
        r = next((r for r in self.requests if r["id"] == request_id), None)
        return {k: r[k] for k in ("id", "owner_id", "status", "wait_until")} if r else None

    def deny_request(self, request_id, owner_id, now):
        with self.lock:
            for r in self.requests:
                if (r["id"] == request_id and r["owner_id"] == owner_id and r["status"] == "pending"
                        and r["wait_until"] > now):
                    r["status"] = "denied"
                    return True
            return False

    def expire_requests(self, owner_id, now):
        with self.lock:
            out = []
            for r in self.requests:
                if r["owner_id"] == owner_id and r["status"] == "pending" and r["wait_until"] <= now:
                    r["status"] = "timeout"
                    out.append(r["wait_until"])
            return out

    def cancel_requests(self, owner_id, now):
        n = 0
        for r in self.requests:
            if r["owner_id"] == owner_id and r["status"] == "pending":
                r["status"] = "cancelled"
                n += 1
        return n

    def latest_request(self, owner_id, guardian_id):
        for r in reversed(self.requests):
            if r["owner_id"] == owner_id and r["guardian_id"] == guardian_id:
                return {"request_id": r["id"], "status": r["status"], "wait_until": r["wait_until"]}
        return None

    def insert_view_token(self, token_hash, guardian_id, owner_id, expires_at):
        self.tokens.append({"token_hash": token_hash, "guardian_id": guardian_id, "owner_id": owner_id,
                            "expires_at": expires_at, "revoked_at": None})

    def revoke_view_tokens(self, owner_id, now):
        n = 0
        for t in self.tokens:
            if t["owner_id"] == owner_id and t["revoked_at"] is None:
                t["revoked_at"] = now
                n += 1
        return n

    def valid_view_token(self, token_hash, guardian_id, owner_id, now):
        return any(t["token_hash"] == token_hash and t["guardian_id"] == guardian_id
                   and t["owner_id"] == owner_id and t["revoked_at"] is None and t["expires_at"] > now
                   for t in self.tokens)

    def insert_document(self, doc_id, owner_id, doc_type, file_name, content_type, s3_key, encrypted_data_key):
        now = datetime.now(timezone.utc)
        self.documents[doc_id] = {"id": doc_id, "owner_id": owner_id, "doc_type": doc_type,
                                  "file_name": file_name, "content_type": content_type, "s3_key": s3_key,
                                  "encrypted_data_key": encrypted_data_key, "uploaded_at": now,
                                  "deleted_at": None}
        return now

    def get_document(self, doc_id):
        d = self.documents.get(doc_id)
        return dict(d) if d else None

    def list_documents(self, owner_id):
        docs = [d for d in self.documents.values() if d["owner_id"] == owner_id and not d["deleted_at"]]
        return [{k: d[k] for k in ("id", "doc_type", "file_name", "content_type", "uploaded_at")}
                for d in sorted(docs, key=lambda d: d["uploaded_at"], reverse=True)]

    def mark_document_deleted(self, doc_id, now):
        d = self.documents.get(doc_id)
        if not d or d["deleted_at"]:
            return False
        d.update(deleted_at=now, encrypted_data_key=b"")
        return True

    def audit(self, actor_id, action, result, deny_reason=None, document_id=None):
        self.audits.append({"actor_id": actor_id, "action": action, "result": result,
                            "deny_reason": deny_reason, "document_id": document_id})
