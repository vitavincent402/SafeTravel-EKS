"""작은 JSON 서버 틀 (api와 vault에 같은 파일이 있음).
웹 프레임워크를 정하기 전까지 파이썬 기본 서버로 주소별 처리를 나눈다."""
import json
import re
import sys
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs


def to_json_value(value):
    """시각은 모두 UTC ISO 형식 (예: 2026-11-24T05:20:00Z)."""
    if isinstance(value, datetime):
        if value.tzinfo is None:
            value = value.replace(tzinfo=timezone.utc)
        return value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return str(value)


def log(event, **fields):
    """한 줄 JSON 로그. 토큰 값, 비밀번호, 서류 내용은 넣지 않는다."""
    print(json.dumps({"event": event, **fields}, ensure_ascii=False, default=to_json_value),
          file=sys.stdout, flush=True)


class RawResponse:
    """JSON이 아닌 응답 (파일, 204 빈 응답)."""

    def __init__(self, status, body=b"", content_type=None, headers=None):
        self.status, self.body, self.content_type, self.headers = status, body, content_type, headers or {}


class HttpError(Exception):
    """오류 응답은 {"error": "..."} 하나로 통일 (화면·문서 담당과 정한 규칙)."""

    def __init__(self, status, error, headers=None):
        super().__init__(error)
        self.status, self.error, self.headers = status, error, headers or {}


def routes(*table):
    """(방식, 경로 정규식, 처리 함수 이름) 목록을 준비한다."""
    return [(m, re.compile(p), name) for m, p, name in table]


class JsonHandler(BaseHTTPRequestHandler):
    ROUTES = []
    MAX_BODY = 1024 * 1024
    server_version = "keeper"
    sys_version = ""
    protocol_version = "HTTP/1.1"

    @property
    def app(self):
        return self.server.app

    def send_json(self, status, body, headers=None):
        data = json.dumps(body, ensure_ascii=False, default=to_json_value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def send_raw(self, resp):
        self.send_response(resp.status)
        if resp.content_type:
            self.send_header("Content-Type", resp.content_type)
        self.send_header("Content-Length", str(len(resp.body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        for k, v in resp.headers.items():
            self.send_header(k, v)
        self.end_headers()
        if resp.body:
            self.wfile.write(resp.body)

    def raw_body(self):
        if not hasattr(self, "_body"):
            length = int(self.headers.get("Content-Length") or 0)
            if length > self.MAX_BODY:
                self.close_connection = True
                raise HttpError(413, "body too large")
            self._body = self.rfile.read(length) if length else b""
        return self._body

    def json_body(self):
        raw = self.raw_body()
        try:
            body = json.loads(raw or b"{}")
        except ValueError:
            raise HttpError(400, "invalid json") from None
        if not isinstance(body, dict):
            raise HttpError(400, "invalid json")
        return body

    def _dispatch(self, method):
        # 핸들러 객체는 연결 하나에 하나만 만들어져 같은 연결의 다음 요청에도 그대로 쓰인다.
        # 이전 요청의 본문(_body)이 남아 있으면 다음 요청이 자기 본문 대신 그 본문을 읽고,
        # 자기 본문은 연결에 남아 그다음 요청이 501로 깨진다. 그래서 요청마다 먼저 지운다.
        vars(self).pop("_body", None)
        self.conn_request_no = getattr(self, "conn_request_no", 0) + 1  # 이 연결의 몇 번째 요청인지(진단용)
        try:
            self._route(method)
        finally:
            self._drain_body()

    def _drain_body(self):
        """처리 중에 읽지 않은 요청 본문을 비운다.
        HTTP/1.1은 연결을 이어 쓰고 ALB도 여러 사용자의 요청에 같은 연결을 쓴다. 본문을 남기면
        같은 연결로 온 다음 요청이 '{}GET /...'처럼 읽혀 http.server가 501을 보낸다(11-25 10:16 사례)."""
        if hasattr(self, "_body"):
            return
        if "chunked" in (self.headers.get("Transfer-Encoding") or "").lower():
            self.close_connection = True  # 길이를 모르는 본문은 읽지 않고 연결을 끊는다
            return
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            self.close_connection = True
            return
        if length > self.MAX_BODY:
            self.close_connection = True  # 너무 큰 본문은 읽지 않고 연결을 끊는다
        elif length > 0:
            self.rfile.read(length)

    def _route(self, method):
        path, _, query = self.path.partition("?")
        self.path_only = path
        self.query = {k: v[0] for k, v in parse_qs(query).items()}
        allowed = False
        for m, rx, name in self.ROUTES:
            match = rx.fullmatch(path)
            if not match:
                continue
            if m != method:
                allowed = True
                continue
            try:
                result = getattr(self, name)(**match.groupdict())
                if isinstance(result, RawResponse):
                    return self.send_raw(result)
                status, body = result if isinstance(result, tuple) else (200, result)
                return self.send_json(status, body)
            except HttpError as e:
                return self.send_json(e.status, {"error": e.error}, e.headers)
            except Exception as e:  # noqa: BLE001
                log("unhandled_error", path=path, error=type(e).__name__)
                return self.send_json(500, {"error": "internal error"})
        if allowed:
            return self.send_json(405, {"error": "method not allowed"})
        return self.send_json(404, {"error": "not found"})

    def do_GET(self):
        self._dispatch("GET")

    def do_POST(self):
        self._dispatch("POST")

    def do_DELETE(self):
        self._dispatch("DELETE")

    def log_message(self, *args):
        pass


def make_server(handler_cls, app, port, host="0.0.0.0"):
    server = ThreadingHTTPServer((host, port), handler_cls)
    server.daemon_threads = True
    server.app = app
    return server
