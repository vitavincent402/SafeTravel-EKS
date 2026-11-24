"""api → vault 요청 (서류 저장·열람·삭제는 vault만 한다).
요청마다 앱 비밀값으로 서명해서 보낸다 (internal_auth.py)."""
import json
import urllib.error
import urllib.request

from internal_auth import sign
from web import HttpError, log


class VaultClient:
    def __init__(self, base_url, signing_key, timeout=15):
        self.base_url = base_url.rstrip("/")
        self.key = signing_key
        self.timeout = timeout

    def call(self, method, path, actor_id, body=None, view_token=None):
        """vault의 응답 (상태 코드, JSON)을 그대로 돌려준다."""
        data = json.dumps(body).encode() if body is not None else b""
        headers = sign(self.key, method, path, actor_id, data, view_token)
        if data:
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(self.base_url + path, data=data or None, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as r:
                return r.status, json.load(r)
        except urllib.error.HTTPError as e:
            try:
                return e.code, json.load(e)
            except ValueError:
                return e.code, {"error": "vault error"}
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            log("vault_unreachable", error=type(e).__name__)
            raise HttpError(503, "vault unavailable") from e

    def health(self):
        try:
            with urllib.request.urlopen(f"{self.base_url}/healthz", timeout=3) as r:
                return json.load(r)
        except Exception as e:  # noqa: BLE001
            return {"error": str(e)}
