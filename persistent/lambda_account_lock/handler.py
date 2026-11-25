"""SOC 승인 -> SQS(FIFO) -> Cognito 계정 잠금/해제. 이 함수는 VPC 밖에서 실행된다(Cognito는 공개 API).

메시지: {"action":"lock"|"unlock","cognito_sub":"<uuid>","username":"표시용","request_id":"...","reason":"..."}
직접 호출(WAS 담당): {"action":"request","cognito_sub":"<uuid>","username":"표시용","reason":"...","ip":"선택"}
  -> 잠그지 않고 soc_lock_request 한 줄만 로그에 남긴다(SOC가 읽어 승인 대기에 올림).
"""
import json
import os
import re
import uuid

import boto3

SUB = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}")
_client = None


def cognito():
    global _client
    if _client is None:
        _client = boto3.client("cognito-idp")
    return _client


def log(event, **fields):
    print(json.dumps({"event": event, **fields}, ensure_ascii=False, separators=(",", ":")))


def clean(value, limit):
    return value[:limit] if isinstance(value, str) else ""


def parse(body):
    data = json.loads(body) if isinstance(body, str) else body
    if not isinstance(data, dict):
        raise ValueError("not an object")
    action = data.get("action")
    sub = data.get("cognito_sub")
    if action not in ("lock", "unlock", "request") or not isinstance(sub, str) or not SUB.fullmatch(sub):
        raise ValueError("invalid action or cognito_sub")
    return {
        "action": action, "cognito_sub": sub,
        "username": clean(data.get("username"), 100), "reason": clean(data.get("reason"), 300),
        "request_id": clean(data.get("request_id"), 128) or str(uuid.uuid4()),
        "ip": clean(data.get("ip"), 45),
    }


def apply(msg):
    client, pool, sub = cognito(), os.environ["USER_POOL_ID"], msg["cognito_sub"]
    base = {"request_id": msg["request_id"], "cognito_sub": sub, "username": msg["username"], "action": msg["action"]}
    try:
        client.admin_get_user(UserPoolId=pool, Username=sub)
    except client.exceptions.UserNotFoundException:
        log("soc_lock_result", result="not_found", **base)
        return
    if msg["action"] == "lock":
        groups = client.admin_list_groups_for_user(UserPoolId=pool, Username=sub)["Groups"]
        if any(g["GroupName"] == "admin" for g in groups):
            log("soc_lock_result", result="refused_admin", **base)
            return
        client.admin_disable_user(UserPoolId=pool, Username=sub)
        client.admin_user_global_sign_out(UserPoolId=pool, Username=sub)
        log("soc_lock_result", result="locked", **base)
    else:
        client.admin_enable_user(UserPoolId=pool, Username=sub)
        log("soc_lock_result", result="unlocked", **base)


def lambda_handler(event, _context):
    if "Records" not in event:
        try:
            msg = parse(event)
        except (ValueError, TypeError) as exc:
            log("soc_lock_invalid", error=str(exc))
            return {"ok": False}
        if msg["action"] != "request":
            return {"ok": False, "error": "use SQS for lock/unlock"}
        log("soc_lock_request", request_id=msg["request_id"], cognito_sub=msg["cognito_sub"],
            username=msg["username"], reason=msg["reason"], ip=msg["ip"], node="was")
        return {"ok": True, "request_id": msg["request_id"]}
    failures = []
    for record in event["Records"]:
        try:
            msg = parse(record["body"])
            if msg["action"] == "request":
                raise ValueError("request is not a queue action")
        except (ValueError, TypeError) as exc:
            # 형식 오류는 재시도해도 같다: 기록만 하고 메시지는 소비한다.
            log("soc_lock_invalid", error=str(exc), message_id=record.get("messageId"))
            continue
        try:
            apply(msg)
        except Exception as exc:  # 일시 오류만 재시도 -> 3회 뒤 DLQ
            log("soc_lock_error", request_id=msg["request_id"], error=type(exc).__name__)
            failures.append({"itemIdentifier": record["messageId"]})
    return {"batchItemFailures": failures}
