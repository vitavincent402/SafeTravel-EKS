"""전체 흐름 시험: 화면·문서 담당의 주소 표 그대로, api와 vault 서버를 실제로 띄워 돌린다.
가짜 Cognito(액세스 토큰 + userInfo), 가짜 KMS, 가짜 S3, 시계를 마음대로 움직이는 Clock을 쓴다.
실행: apps/api 폴더에서  python -m pytest -q tests
"""
import importlib.util
import io
import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timedelta, timezone

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

HERE = os.path.dirname(os.path.abspath(__file__))
API_DIR = os.path.dirname(HERE)
VAULT_DIR = os.path.join(os.path.dirname(API_DIR), "vault")
sys.path.insert(0, API_DIR)
sys.path.append(VAULT_DIR)  # crypto.py

from auth import CognitoVerifier  # noqa: E402
from internal_auth import sign  # noqa: E402
from main import ApiHandler, App  # noqa: E402
from store import MemoryStore  # noqa: E402
from vault_client import VaultClient  # noqa: E402
from web import make_server  # noqa: E402

_spec = importlib.util.spec_from_file_location("vault_main", os.path.join(VAULT_DIR, "main.py"))
vault_main = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(vault_main)

REGION, POOL, CLIENT = "ap-northeast-2", "ap-northeast-2_TESTPOOL", "test-client-id"
ISSUER = f"https://cognito-idp.{REGION}.amazonaws.com/{POOL}"
SIGNING_KEY = b"test-signing-key-0123456789abcdef0123456789"

_priv = rsa.generate_private_key(public_exponent=65537, key_size=2048)
_jwk = json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(_priv.public_key()))
_jwk.update(kid="k1", alg="RS256")

PEOPLE = {  # Cognito에 있는 사람들 (userInfo가 돌려주는 값)
    "sub-owner": {"email": "owner@example.com", "name": "여행자"},
    "sub-guardian": {"email": "guardian@example.com", "name": "보호자"},
    "sub-stranger": {"email": "stranger@example.com", "name": "공격자"},
}
TOKEN_TO_SUB = {}


def access_token(sub):
    now = int(time.time())
    tok = jwt.encode({"sub": sub, "client_id": CLIENT, "token_use": "access", "scope": "openid email profile",
                      "iss": ISSUER, "iat": now, "exp": now + 3600}, _priv, algorithm="RS256",
                     headers={"kid": "k1"})
    TOKEN_TO_SUB[tok] = sub
    return tok


OWNER, GUARDIAN, STRANGER = (access_token(s) for s in ("sub-owner", "sub-guardian", "sub-stranger"))
USERINFO_CALLS = []


def fake_userinfo(tok):
    USERINFO_CALLS.append(tok)
    sub = TOKEN_TO_SUB[tok]
    return {"sub": sub, "email_verified": "true", **PEOPLE[sub]}


PNG = b"\x89PNG\r\n\x1a\n" + b"passport-image-bytes" * 10
JPEG = b"\xff\xd8\xff\xe0" + b"insurance" * 10


class FakeKMS:
    """진짜 KMS처럼: 데이터 키를 만들고, 암호화 문맥이 같아야만 풀어 준다."""

    def __init__(self):
        self.master = AESGCM(AESGCM.generate_key(bit_length=256))

    def generate_data_key(self, KeyId, KeySpec, EncryptionContext):
        key, nonce = os.urandom(32), os.urandom(12)
        aad = json.dumps(EncryptionContext, sort_keys=True).encode()
        return {"Plaintext": key, "CiphertextBlob": nonce + self.master.encrypt(nonce, key, aad)}

    def decrypt(self, CiphertextBlob, KeyId, EncryptionContext):
        aad = json.dumps(EncryptionContext, sort_keys=True).encode()
        return {"Plaintext": self.master.decrypt(CiphertextBlob[:12], CiphertextBlob[12:], aad)}


class FakeS3:
    def __init__(self):
        self.objects = {}

    def put_object(self, Bucket, Key, Body, ContentType):
        self.objects[Key] = Body

    def get_object(self, Bucket, Key):
        return {"Body": io.BytesIO(self.objects[Key])}

    def delete_object(self, Bucket, Key):
        self.objects.pop(Key, None)


class Clock:
    def __init__(self):
        self.t = datetime.now(timezone.utc).replace(microsecond=0)

    def __call__(self):
        return self.t

    def advance(self, **kw):
        self.t += timedelta(**kw)


@pytest.fixture
def env():
    store, kms, s3, clock = MemoryStore(), FakeKMS(), FakeS3(), Clock()
    vsrv = make_server(vault_main.VaultHandler,
                       vault_main.VaultApp(store, kms, s3, "bucket", "kms-key", SIGNING_KEY, now=clock),
                       0, host="127.0.0.1")
    threading.Thread(target=vsrv.serve_forever, daemon=True).start()
    vault_url = f"http://127.0.0.1:{vsrv.server_address[1]}"
    verifier = CognitoVerifier(REGION, POOL, CLIENT, fetch_jwks=lambda: {"keys": [_jwk]},
                               fetch_userinfo=fake_userinfo)
    asrv = make_server(ApiHandler, App(verifier, store, VaultClient(vault_url, SIGNING_KEY), now=clock),
                       0, host="127.0.0.1")
    threading.Thread(target=asrv.serve_forever, daemon=True).start()
    yield {"api": f"http://127.0.0.1:{asrv.server_address[1]}", "vault": vault_url,
           "store": store, "s3": s3, "clock": clock, "kms": kms}
    asrv.shutdown()
    vsrv.shutdown()


def call(base, method, path, tok=None, body=None, view_token=None, headers=None, raw=None, ctype=None):
    h = dict(headers or {})
    if tok:
        h["Authorization"] = f"Bearer {tok}"
    if view_token:
        h["X-View-Token"] = view_token
    data = raw
    if body is not None:
        data, h["Content-Type"] = json.dumps(body).encode(), "application/json"
    if ctype:
        h["Content-Type"] = ctype
    req = urllib.request.Request(base + path, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            payload = r.read()
            if r.headers.get("Content-Type", "").startswith("application/json"):
                return r.status, json.loads(payload)
            return r.status, payload, dict(r.headers)
    except urllib.error.HTTPError as e:
        return e.code, json.load(e)


def upload(api, tok, title, filename, content):
    boundary = "----keeper" + uuid.uuid4().hex
    body = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\n{title}\r\n"
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{filename}\"\r\n"
            f"Content-Type: application/octet-stream\r\n\r\n").encode() + content + f"\r\n--{boundary}--\r\n".encode()
    return call(api, "POST", "/api/docs", tok, raw=body, ctype=f"multipart/form-data; boundary={boundary}")


ISO_Z = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")


def setup_people(e):
    api = e["api"]
    owner = call(api, "GET", "/api/me", OWNER)[1]
    guardian = call(api, "GET", "/api/me", GUARDIAN)[1]
    assert call(api, "POST", "/api/guardians", OWNER, {"email": "guardian@example.com"})[0] == 201
    code, doc = upload(api, OWNER, "여권", "passport.png", PNG)
    assert code == 201, doc
    return owner, guardian, doc["id"]


def test_me_모양과_userInfo는_처음_한번만(env):
    api = env["api"]
    USERINFO_CALLS.clear()
    code, me = call(api, "GET", "/api/me", OWNER)
    assert code == 200
    assert me["name"] == "여행자" and me["role"] == "user"
    assert me["emergency"] is False and me["emergency_since"] is None and me["emergency_reason"] is None
    call(api, "GET", "/api/me", OWNER)
    assert len(USERINFO_CALLS) == 1  # 두 번째부터는 DB에서 찾음


def test_전체_흐름(env):
    api, store, s3, clock = env["api"], env["store"], env["s3"], env["clock"]
    owner, guardian, doc_id = setup_people(env)
    assert call(api, "GET", "/api/me", GUARDIAN)[1]["role"] == "guardian"

    # [여행자] 목록·열람
    docs = call(api, "GET", "/api/docs", OWNER)[1]
    assert docs[0]["id"] == doc_id and docs[0]["title"] == "여권" and ISO_Z.match(docs[0]["uploaded_at"])
    status, content, headers = call(api, "GET", f"/api/docs/{doc_id}", OWNER)
    assert status == 200 and content == PNG and headers["Content-Type"] == "image/png"
    assert "sandbox" in headers["Content-Security-Policy"]
    # 저장된 것은 암호문
    assert PNG not in next(iter(s3.objects.values()))

    # [보호자] 처음: 비상 아님, 요청 없음
    t = call(api, "GET", "/api/guardian/travelers", GUARDIAN)[1]
    assert t == [{"user_id": owner["id"], "name": "여행자", "emergency": False,
                  "emergency_since": None, "emergency_reason": None, "request": None}]
    assert call(api, "POST", "/api/guardian/view-token", GUARDIAN, {"user_id": owner["id"]}) == \
        (403, {"error": "not_emergency"})
    assert call(api, "GET", f"/api/guardian/docs/{doc_id}", GUARDIAN)[0] == 403

    # 요청 → 여행자에게 대기 요청이 보임
    code, req = call(api, "POST", "/api/guardian/requests", GUARDIAN, {"user_id": owner["id"]})
    assert code == 201 and ISO_Z.match(req["wait_until"])
    assert call(api, "POST", "/api/guardian/requests", GUARDIAN, {"user_id": owner["id"]}) == \
        (409, {"error": "already_pending"})
    code, pending = call(api, "GET", "/api/requests/pending", OWNER)
    assert pending == {"request_id": req["request_id"], "guardian_name": "보호자",
                       "expires_at": req["wait_until"]}
    t = call(api, "GET", "/api/guardian/travelers", GUARDIAN)[1][0]
    assert t["request"]["status"] == "pending" and t["request"]["wait_until"] == req["wait_until"]

    # 1분 무응답 → timeout, 자동 비상
    clock.advance(seconds=60)
    status, *_ = call(api, "GET", "/api/requests/pending", OWNER)
    assert status == 204
    me = call(api, "GET", "/api/me", OWNER)[1]
    assert me["emergency"] is True and me["emergency_reason"] == "auto" and me["emergency_since"] == req["wait_until"]
    t = call(api, "GET", "/api/guardian/travelers", GUARDIAN)[1][0]
    assert t["emergency"] is True and t["request"]["status"] == "timeout"
    # 시간이 지난 요청은 거절할 수 없음
    assert call(api, "POST", f"/api/requests/{req['request_id']}/deny", OWNER) == (409, {"error": "not_pending"})

    # 열람 토큰 → 목록·파일
    assert call(api, "GET", f"/api/guardian/travelers/{owner['id']}/docs", GUARDIAN) == \
        (403, {"error": "no_view_token"})
    code, vt = call(api, "POST", "/api/guardian/view-token", GUARDIAN, {"user_id": owner["id"]})
    assert code == 201 and ISO_Z.match(vt["expires_at"])
    docs = call(api, "GET", f"/api/guardian/travelers/{owner['id']}/docs", GUARDIAN, view_token=vt["view_token"])[1]
    assert [d["id"] for d in docs] == [doc_id]
    status, content, _ = call(api, "GET", f"/api/guardian/docs/{doc_id}", GUARDIAN, view_token=vt["view_token"])
    assert status == 200 and content == PNG

    # 열람 기록 = 실제로 본 서류 (목록은 열람으로 세지 않음)
    views = [a for a in store.audits if a["action"] == "document_view" and a["result"] == "allowed"]
    assert [(a["actor_id"], a["document_id"]) for a in views] == [(owner["id"], doc_id), (guardian["id"], doc_id)]

    # 비상 해제 → 토큰 취소
    assert call(api, "POST", "/api/sos/cancel", OWNER)[1]["emergency"] is False
    assert call(api, "GET", f"/api/guardian/docs/{doc_id}", GUARDIAN, view_token=vt["view_token"]) == \
        (403, {"error": "not_emergency"})
    assert call(api, "POST", "/api/sos", OWNER) == (200, {"emergency": True})
    assert call(api, "POST", "/api/sos", OWNER) == (409, {"error": "already_emergency"})
    assert call(api, "GET", f"/api/guardian/docs/{doc_id}", GUARDIAN, view_token=vt["view_token"]) == \
        (403, {"error": "invalid_view_token"})
    assert call(api, "GET", "/api/me", OWNER)[1]["emergency_reason"] == "sos"


def test_거절(env):
    api, clock = env["api"], env["clock"]
    owner, _, _ = setup_people(env)
    req = call(api, "POST", "/api/guardian/requests", GUARDIAN, {"user_id": owner["id"]})[1]
    clock.advance(seconds=30)
    assert call(api, "POST", f"/api/requests/{req['request_id']}/deny", OWNER) == (200, {"denied": True})
    clock.advance(seconds=60)  # 거절했으니 시간이 지나도 비상이 되지 않음
    assert call(api, "GET", "/api/me", OWNER)[1]["emergency"] is False
    assert call(api, "GET", "/api/guardian/travelers", GUARDIAN)[1][0]["request"]["status"] == "denied"
    # 다른 사람이 남의 요청을 거절할 수 없음
    req2 = call(api, "POST", "/api/guardian/requests", GUARDIAN, {"user_id": owner["id"]})[1]
    assert call(api, "POST", f"/api/requests/{req2['request_id']}/deny", GUARDIAN)[0] == 404


def test_SOS중_요청은_409이고_해제하면_대기요청_취소(env):
    api, clock = env["api"], env["clock"]
    owner, _, _ = setup_people(env)
    call(api, "POST", "/api/guardian/requests", GUARDIAN, {"user_id": owner["id"]})
    call(api, "POST", "/api/sos", OWNER)  # 대기 요청은 취소됨
    assert call(api, "POST", "/api/guardian/requests", GUARDIAN, {"user_id": owner["id"]}) == \
        (409, {"error": "already_emergency"})
    call(api, "POST", "/api/sos/cancel", OWNER)
    clock.advance(minutes=5)
    assert call(api, "GET", "/api/me", OWNER)[1]["emergency"] is False  # 취소된 요청이 나중에 비상을 만들지 않음


def test_토큰_만료(env):
    api, clock = env["api"], env["clock"]
    owner, _, doc_id = setup_people(env)
    call(api, "POST", "/api/sos", OWNER)
    vt = call(api, "POST", "/api/guardian/view-token", GUARDIAN, {"user_id": owner["id"]})[1]["view_token"]
    clock.advance(minutes=14, seconds=59)
    assert call(api, "GET", f"/api/guardian/docs/{doc_id}", GUARDIAN, view_token=vt)[0] == 200
    clock.advance(seconds=1)
    assert call(api, "GET", f"/api/guardian/docs/{doc_id}", GUARDIAN, view_token=vt) == \
        (403, {"error": "invalid_view_token"})


def test_보호자가_아니면_거부(env):
    api = env["api"]
    owner, _, doc_id = setup_people(env)
    call(api, "POST", "/api/sos", OWNER)
    vt = call(api, "POST", "/api/guardian/view-token", GUARDIAN, {"user_id": owner["id"]})[1]["view_token"]
    # 공격자가 보호자의 토큰을 훔쳐도 거부
    assert call(api, "GET", f"/api/guardian/docs/{doc_id}", STRANGER, view_token=vt) == \
        (403, {"error": "not_guardian"})
    assert call(api, "POST", "/api/guardian/view-token", STRANGER, {"user_id": owner["id"]}) == \
        (403, {"error": "not_guardian"})
    assert call(api, "POST", "/api/guardian/requests", STRANGER, {"user_id": owner["id"]})[0] == 403
    assert call(api, "GET", "/api/guardian/travelers", STRANGER)[1] == []
    # 여행자 주소로 남의 서류를 보려 해도 거부 (토큰 없음)
    assert call(api, "GET", f"/api/docs/{doc_id}", STRANGER)[0] == 403


def test_로그인_없으면_401(env):
    api = env["api"]
    for path in ("/api/me", "/api/docs", "/api/guardian/travelers", "/api/requests/pending"):
        assert call(api, "GET", path) == (401, {"error": "login required"})


def test_업로드_검사(env):
    api, store = env["api"], env["store"]
    setup_people(env)
    # HTML을 그림인 척 올려도 거부 (내용으로 판단)
    assert upload(api, OWNER, "가짜", "evil.png", b"<html><script>alert(1)</script></html>")[0] == 415
    assert upload(api, OWNER, "보험", "ins.jpg", JPEG)[0] == 201
    assert upload(api, OWNER, "", "a.png", PNG)[0] == 400
    assert upload(api, OWNER, "큰 파일", "big.png", PNG + b"x" * (5 * 1024 * 1024))[0] == 413
    code, doc = upload(api, OWNER, "경로", "../../etc/passwd.png", PNG)
    assert code == 201 and store.documents[doc["id"]]["file_name"] == "passwd.png"
    assert call(api, "POST", "/api/docs", OWNER, {"title": "x"})[0] == 400  # multipart 아님


def test_vault는_서명_없는_요청을_거부(env):
    v = env["vault"]
    owner_id = env["store"].login("s", "a@b.c", "a")["id"]
    assert call(v, "GET", "/documents", headers={"X-Keeper-Actor": owner_id})[0] == 401
    assert call(v, "GET", "/documents", headers=sign(b"wrong-key", "GET", "/documents", owner_id))[0] == 401
    old = sign(SIGNING_KEY, "GET", "/documents", owner_id, ts=int(time.time()) - 120)
    assert call(v, "GET", "/documents", headers=old)[0] == 401
    assert call(v, "GET", "/documents", headers=sign(SIGNING_KEY, "GET", "/documents", owner_id))[0] == 200


def test_서류_삭제와_키_파기(env):
    api, store, s3 = env["api"], env["store"], env["s3"]
    _, _, doc_id = setup_people(env)
    assert call(api, "DELETE", f"/api/docs/{doc_id}", GUARDIAN) == (403, {"error": "not_owner"})
    assert call(api, "DELETE", f"/api/docs/{doc_id}", OWNER)[0] == 200
    assert s3.objects == {} and store.documents[doc_id]["encrypted_data_key"] == b""
    assert call(api, "GET", f"/api/docs/{doc_id}", OWNER) == (404, {"error": "not_found"})
    assert call(api, "GET", "/api/docs", OWNER)[1] == []


def test_암호화_문맥이_다르거나_내용이_바뀌면_복호화_실패(env):
    import crypto
    kms = env["kms"]
    blob, key = crypto.encrypt_document(kms, "k", b"data", {"document_id": "A", "owner_id": "O"})
    assert crypto.decrypt_document(kms, "k", blob, key, {"document_id": "A", "owner_id": "O"}) == b"data"
    with pytest.raises(Exception):
        crypto.decrypt_document(kms, "k", blob, key, {"document_id": "B", "owner_id": "O"})
    with pytest.raises(crypto.DecryptError):
        crypto.decrypt_document(kms, "k", blob[:-1] + bytes([blob[-1] ^ 1]), key,
                                {"document_id": "A", "owner_id": "O"})
