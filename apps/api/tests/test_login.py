"""로그인 시험: 직접 만든 키로 가짜 Cognito 토큰을 만들어 api가 제대로 걸러 내는지 본다.
실행: apps/api 폴더에서  python -m pytest -q tests
"""
import base64
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.request

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from auth import CognitoVerifier, KeysUnavailable, TokenError  # noqa: E402
from main import ApiHandler, App  # noqa: E402
from store import MemoryStore  # noqa: E402
from users import LoginRefused, profile_from_claims  # noqa: E402
from web import make_server  # noqa: E402

REGION, POOL, CLIENT = "ap-northeast-2", "ap-northeast-2_TESTPOOL", "test-client-id"
ISSUER = f"https://cognito-idp.{REGION}.amazonaws.com/{POOL}"


def make_key(kid):
    priv = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    jwk = json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(priv.public_key()))
    jwk.update(kid=kid, alg="RS256", use="sig")
    return priv, jwk


KEY1, JWK1 = make_key("kid-1")
OTHER_KEY, _ = make_key("kid-1")  # 같은 kid, 다른 키 = 위조


def token(key=KEY1, kid="kid-1", **over):
    now = int(time.time())
    claims = {
        "sub": "sub-owner", "email": "owner@example.com", "email_verified": True,
        "name": "서류주인", "iss": ISSUER, "aud": CLIENT, "token_use": "id",
        "iat": now, "exp": now + 3600,
    }
    claims.update(over)
    claims = {k: v for k, v in claims.items() if v is not None}
    return jwt.encode(claims, key, algorithm="RS256", headers={"kid": kid})


@pytest.fixture
def verifier():
    return CognitoVerifier(REGION, POOL, CLIENT, fetch_jwks=lambda: {"keys": [JWK1]})


# ---------- 토큰 확인 (auth.py) ----------

def test_정상_토큰은_통과(verifier):
    assert verifier.verify(token())["sub"] == "sub-owner"


@pytest.mark.parametrize("over", [
    {"exp": int(time.time()) - 120},                         # 만료
    {"aud": "other-client"},                                 # 다른 앱 클라이언트용
    {"iss": "https://cognito-idp.ap-northeast-2.amazonaws.com/other"},  # 다른 풀
    {"token_use": None},                                     # 종류 없음
    {"token_use": "refresh"},                                # 다른 종류
])
def test_조건이_틀린_토큰은_거부(verifier, over):
    with pytest.raises(TokenError):
        verifier.verify(token(**over))


def test_액세스_토큰은_client_id로_확인(verifier):
    def access(**over):
        c = {"token_use": "access", "client_id": CLIENT, "aud": None, "email": None, "name": None}
        c.update(over)
        return token(**c)
    assert verifier.verify(access())["token_use"] == "access"
    with pytest.raises(TokenError):
        verifier.verify(access(client_id="other-client"))
    with pytest.raises(TokenError):
        verifier.verify(access(client_id=None))


def test_ID_토큰은_aud로_확인(verifier):
    with pytest.raises(TokenError):
        verifier.verify(token(aud=None))


def test_위조된_서명은_거부(verifier):
    with pytest.raises(TokenError):
        verifier.verify(token(key=OTHER_KEY))


def test_모르는_kid는_거부(verifier):
    with pytest.raises(TokenError):
        verifier.verify(token(kid="kid-unknown"))


def test_HS256_바꿔치기는_거부(verifier):
    forged = jwt.encode({"sub": "x", "iss": ISSUER, "aud": CLIENT, "token_use": "id",
                         "iat": 0, "exp": 9999999999}, "secret", algorithm="HS256",
                        headers={"kid": "kid-1"})
    with pytest.raises(TokenError):
        verifier.verify(forged)


def test_alg_none은_거부(verifier):
    def b64(d):
        return base64.urlsafe_b64encode(json.dumps(d).encode()).rstrip(b"=").decode()
    forged = f'{b64({"alg": "none", "kid": "kid-1"})}.{b64({"sub": "x"})}.'
    with pytest.raises(TokenError):
        verifier.verify(forged)


def test_엉터리_문자열은_거부(verifier):
    with pytest.raises(TokenError):
        verifier.verify("not-a-token")


def test_키가_바뀌면_다시_받아옴():
    key2, jwk2 = make_key("kid-2")
    served = {"keys": [JWK1]}
    v = CognitoVerifier(REGION, POOL, CLIENT, fetch_jwks=lambda: served, min_refresh_interval=0)
    v.verify(token())
    served = {"keys": [JWK1, jwk2]}
    v._fetch = lambda: served
    assert v.verify(token(key=key2, kid="kid-2"))["sub"] == "sub-owner"


def test_공개키를_못받으면_KeysUnavailable():
    def fail():
        raise OSError("network down")
    v = CognitoVerifier(REGION, POOL, CLIENT, fetch_jwks=fail)
    with pytest.raises(KeysUnavailable):
        v.verify(token())


# ---------- 토큰 내용 → 사용자 정보 (users.py) ----------

def test_이메일_미확인은_거부():
    with pytest.raises(LoginRefused):
        profile_from_claims({"sub": "s", "email": "a@b.c", "email_verified": False})


def test_이름이_없으면_이메일_앞부분():
    assert profile_from_claims({"sub": "s", "email": "Kim@Example.com",
                                "email_verified": "true"}) == ("s", "kim@example.com", "kim")


# ---------- /api/me (main.py) ----------

@pytest.fixture
def server(verifier):
    store = MemoryStore()
    srv = make_server(ApiHandler, App(verifier, store), 0, host="127.0.0.1")
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{srv.server_address[1]}", store
    srv.shutdown()


def get(url, tok=None):
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {tok}"} if tok else {})
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        return e.code, json.load(e)


def test_me_첫_로그인에_사용자를_만들고_두번째는_같은_사용자(server):
    base, store = server
    code, body = get(f"{base}/api/me", token())
    assert code == 200 and body["role"] == "user" and body["email"] == "owner@example.com"
    code2, body2 = get(f"{base}/api/me", token())
    assert code2 == 200 and body2["id"] == body["id"] and len(store.users) == 1


def test_me_보호자로_등록된_사람은_guardian(server):
    base, store = server
    _, owner = get(f"{base}/api/me", token())
    _, body = get(f"{base}/api/me", token(sub="sub-guardian", email="guardian@example.com"))
    store.add_guardian(owner["id"], body["id"])
    _, body = get(f"{base}/api/me", token(sub="sub-guardian", email="guardian@example.com"))
    assert body["role"] == "user"          # 초대만 받은 상태(수락 전)는 보호자가 아님
    store.accept_invite(owner["id"], body["id"])
    _, body = get(f"{base}/api/me", token(sub="sub-guardian", email="guardian@example.com"))
    assert body["role"] == "guardian"


def test_me_토큰_없으면_401(server):
    base, _ = server
    assert get(f"{base}/api/me")[0] == 401


def test_me_위조_토큰은_401(server):
    base, store = server
    assert get(f"{base}/api/me", token(key=OTHER_KEY))[0] == 401
    assert store.users == {}  # 사용자도 만들어지지 않음


def test_me_같은_이메일_다른_계정은_409(server):
    base, _ = server
    get(f"{base}/api/me", token())
    assert get(f"{base}/api/me", token(sub="sub-other"))[0] == 409


def test_healthz(server):
    base, _ = server
    assert get(f"{base}/healthz") == (200, {"status": "ok"})


def test_로그인_설정이_없으면_503():
    srv = make_server(ApiHandler, App(None, MemoryStore()), 0, host="127.0.0.1")
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        assert get(f"http://127.0.0.1:{srv.server_address[1]}/api/me", "x")[0] == 503
    finally:
        srv.shutdown()
