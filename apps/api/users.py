"""로그인한 사람을 우리 DB의 users table과 연결 (앱·데이터 담당).

- Cognito 고유 번호(sub)로 사용자를 찾고, 없으면 처음 로그인한 것이므로 새로 만든다.
- 이메일과 이름은 토큰에 들어 있는 값을 쓴다 (Cognito가 원본).
- 역할(role)은 table에 저장하지 않고 매번 계산한다 (임시 규칙):
    누군가의 보호자로 등록되어 있으면 "guardian", 아니면 "user".
"""
from dataclasses import dataclass, asdict


class LoginRefused(Exception):
    """토큰은 맞지만 로그인을 받아 줄 수 없음 (이메일 미확인 등). 화면에는 403."""


class EmailConflict(Exception):
    """같은 이메일을 다른 Cognito 계정이 이미 쓰고 있음. 화면에는 409."""


@dataclass
class User:
    id: str
    email: str
    name: str
    role: str

    def to_dict(self):
        return asdict(self)


def _is_true(value):
    return value is True or (isinstance(value, str) and value.lower() == "true")


def profile_from_claims(claims):
    """토큰 내용에서 (sub, email, name)을 꺼낸다."""
    sub = claims.get("sub")
    email = (claims.get("email") or "").strip().lower()
    if not sub or not email:
        raise LoginRefused("토큰에 sub 또는 email이 없음")
    # 보호자를 이메일로 찾기 때문에, 확인된 이메일만 받는다
    if not _is_true(claims.get("email_verified")):
        raise LoginRefused("이메일이 확인되지 않음")
    name = (claims.get("name") or "").strip() or email.split("@")[0]
    return sub, email, name


UPSERT_USER_SQL = """
INSERT INTO users (email, name, cognito_sub)
VALUES (%s, %s, %s)
ON CONFLICT (cognito_sub) DO UPDATE
    SET email = EXCLUDED.email, name = EXCLUDED.name
RETURNING id::text, email, name
"""

IS_GUARDIAN_SQL = "SELECT EXISTS (SELECT 1 FROM guardians WHERE guardian_id = %s)"


class PostgresUserStore:
    """connect: 호출하면 psycopg 연결을 돌려주는 함수 (db.py가 만듦)."""

    def __init__(self, connect):
        self._connect = connect

    def login(self, sub, email, name):
        try:
            with self._connect() as conn, conn.cursor() as cur:
                cur.execute(UPSERT_USER_SQL, (email, name, sub))
                user_id, email, name = cur.fetchone()
                cur.execute(IS_GUARDIAN_SQL, (user_id,))
                is_guardian = cur.fetchone()[0]
        except Exception as e:
            if getattr(e, "sqlstate", None) == "23505":  # UNIQUE 위반 = 이메일 중복
                raise EmailConflict(email) from e
            raise
        return User(user_id, email, name, "guardian" if is_guardian else "user")


class MemoryUserStore:
    """DB 없이 시험할 때 쓰는 가짜 저장소."""

    def __init__(self):
        self.users = {}           # sub -> dict
        self.guardian_ids = set()  # 보호자로 등록된 user id
        self._seq = 0

    def login(self, sub, email, name):
        for other_sub, u in self.users.items():
            if u["email"] == email and other_sub != sub:
                raise EmailConflict(email)
        if sub not in self.users:
            self._seq += 1
            self.users[sub] = {"id": f"user-{self._seq}"}
        u = self.users[sub]
        u.update(email=email, name=name)
        role = "guardian" if u["id"] in self.guardian_ids else "user"
        return User(u["id"], email, name, role)
