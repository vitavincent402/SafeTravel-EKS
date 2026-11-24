"""로그인한 사람의 정보 정리 (앱·데이터 담당).

- 토큰 내용(claims)에서 Cognito 고유 번호(sub), 이메일, 이름을 꺼낸다.
- users table 행은 store.login()이 찾거나 처음이면 만든다.
- 역할(role)은 table에 저장하지 않고 매번 계산한다 (임시 규칙):
    누군가의 보호자로 등록되어 있으면 "guardian", 아니면 "user".
"""
from dataclasses import asdict, dataclass


class LoginRefused(Exception):
    """토큰은 맞지만 로그인을 받아 줄 수 없음 (이메일 미확인 등). 화면에는 403."""


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


def user_from_row(row):
    return User(row["id"], row["email"], row["name"], "guardian" if row["is_guardian"] else "user")
