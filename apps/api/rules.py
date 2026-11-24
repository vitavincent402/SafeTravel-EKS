"""비상 상태·열람 요청·열람 토큰 규칙 (api와 vault에 같은 파일이 있음).

비상 상태: normal(평상) / emergency(비상)
  여행자 SOS                         → emergency (reason = sos)
  보호자 열람 요청                    → access_requests에 pending, wait_until = 요청 + 1분
  여행자가 wait_until 전에 거절       → denied (비상 아님)
  wait_until까지 응답 없음            → timeout, 여행자는 emergency (reason = auto)
  여행자 SOS 해제                     → normal, 대기 요청 cancelled, 열람 토큰 모두 취소
비상일 때만 보호자가 열람 토큰(15분)을 받을 수 있다.
"""
import hashlib
import os
import secrets
from datetime import timedelta

REQUEST_WAIT = timedelta(seconds=int(os.environ.get("REQUEST_WAIT_SECONDS", "60")))
VIEW_TOKEN_LIFETIME = timedelta(minutes=int(os.environ.get("VIEW_TOKEN_MINUTES", "15")))


def settle_requests(store, owner_id, now):
    """시간이 지난 대기 요청을 timeout으로 바꾸고, 여행자를 자동 비상으로 바꾼다.
    UPDATE ... RETURNING 한 번으로 처리해서, api 파드 두 개가 동시에 불러도 한 번만 바뀐다."""
    expired = store.expire_requests(owner_id, now)
    if not expired:
        return False
    state = store.get_emergency(owner_id)
    if state and state["status"] == "emergency":
        return False
    store.set_emergency(owner_id, "emergency", "auto", min(expired))
    store.audit(owner_id, "emergency_auto", "allowed")
    return True


def emergency_info(store, owner_id):
    """화면에 보여 줄 비상 정보 {emergency, emergency_since, emergency_reason}."""
    state = store.get_emergency(owner_id)
    on = bool(state and state["status"] == "emergency")
    return {"emergency": on,
            "emergency_since": state["changed_at"] if on else None,
            "emergency_reason": state["trigger_source"] if on else None}


def new_view_token():
    """(보호자에게 줄 토큰 값, DB에 저장할 해시). 값 자체는 DB에 저장하지 않는다."""
    token = secrets.token_urlsafe(32)
    return token, hash_view_token(token)


def hash_view_token(token):
    return hashlib.sha256(token.encode()).hexdigest()


def access_denied_reason(store, actor_id, owner_id, view_token, now):
    """서류를 볼 수 있으면 None, 아니면 거부 이유.
    여행자 본인: 항상 허용
    다른 사람: 보호자 + 비상 상태 + 유효한 열람 토큰(만료·취소 안 됨, 이 보호자·이 여행자 것)"""
    if actor_id == owner_id:
        return None
    if not store.is_guardian(owner_id, actor_id):
        return "not_guardian"
    settle_requests(store, owner_id, now)
    if not emergency_info(store, owner_id)["emergency"]:
        return "not_emergency"
    if not view_token:
        return "no_view_token"
    if not store.valid_view_token(hash_view_token(view_token), actor_id, owner_id, now):
        return "invalid_view_token"
    return None
