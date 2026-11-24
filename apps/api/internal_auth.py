"""api → vault 요청 서명 (api와 vault에 같은 파일이 있음).

NetworkPolicy가 api만 vault에 닿게 막지만, 한 겹 더 막는다:
api는 앱 비밀값(token_signing_key)으로 요청에 서명하고, vault는 서명이 맞는 요청만 받는다.
서명에 들어가는 것: 방식(GET 등), 경로, 요청한 사람(actor), 시각, 본문 해시, 열람 토큰 해시.
시각이 60초 넘게 차이 나면 거부한다 (오래된 요청을 다시 보내는 것을 줄임).
"""
import hashlib
import hmac
import time

HEADER_ACTOR = "X-Keeper-Actor"
HEADER_TIME = "X-Keeper-Time"
HEADER_SIG = "X-Keeper-Signature"
HEADER_VIEW_TOKEN = "X-View-Token"
MAX_SKEW_SECONDS = 60


class SignatureError(Exception):
    pass


def _message(method, path, actor, ts, body, view_token):
    body_hash = hashlib.sha256(body or b"").hexdigest()
    token_hash = hashlib.sha256((view_token or "").encode()).hexdigest()
    return "\n".join([method.upper(), path, actor, str(ts), body_hash, token_hash]).encode()


def sign(key, method, path, actor, body=b"", view_token=None, ts=None):
    """보낼 헤더를 돌려준다."""
    ts = int(time.time()) if ts is None else ts
    sig = hmac.new(key, _message(method, path, actor, ts, body, view_token), hashlib.sha256).hexdigest()
    headers = {HEADER_ACTOR: actor, HEADER_TIME: str(ts), HEADER_SIG: sig}
    if view_token:
        headers[HEADER_VIEW_TOKEN] = view_token
    return headers


def verify(key, method, path, headers, body=b"", now=None):
    """서명이 맞으면 actor(요청한 사람의 users.id)를 돌려준다."""
    actor = headers.get(HEADER_ACTOR) or ""
    ts_raw = headers.get(HEADER_TIME) or ""
    sig = headers.get(HEADER_SIG) or ""
    if not (actor and ts_raw.isdigit() and sig):
        raise SignatureError("서명 헤더 없음")
    now = int(time.time()) if now is None else now
    if abs(now - int(ts_raw)) > MAX_SKEW_SECONDS:
        raise SignatureError("시각 차이가 큼")
    expected = hmac.new(key, _message(method, path, actor, ts_raw, body, headers.get(HEADER_VIEW_TOKEN)),
                        hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expected, sig):
        raise SignatureError("서명 불일치")
    return actor
