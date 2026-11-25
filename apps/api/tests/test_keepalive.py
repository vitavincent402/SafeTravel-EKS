"""연결 재사용 시험: 본문을 읽지 않는 요청 뒤에 같은 연결로 다음 요청을 보내도 깨지지 않는지.
11-25 10:16 보호자 서류 목록 GET이 501로 한 번 실패한 사례의 재현.
원인: POST /api/sos 처럼 본문을 읽지 않는 처리 뒤에 본문이 연결에 남아, 다음 요청이 '{}GET ...'으로 읽힘.
"""
import http.client
import os
import sys
import threading

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

from web import JsonHandler, make_server, routes  # noqa: E402


class Handler(JsonHandler):
    ROUTES = routes(
        ("POST", r"/no-read", "no_read"),      # 본문을 읽지 않는 처리 (sos, sos/cancel, deny와 같음)
        ("POST", r"/deny", "deny"),            # 본문을 읽기 전에 오류로 끝나는 처리 (로그인 실패 401 등)
        ("POST", r"/echo", "echo"),            # 본문을 읽어 그대로 돌려줌 (업로드·보호자 등록과 같음)
        ("GET", r"/ping", "ping"),
    )
    MAX_BODY = 1024

    def no_read(self):
        return {"ok": True}

    def deny(self):
        from web import HttpError
        raise HttpError(401, "unauthorized")

    def echo(self):
        return {"got": self.raw_body().decode()}

    def ping(self):
        return {"pong": True}


@pytest.fixture()
def server():
    srv = make_server(Handler, app=None, port=0, host="127.0.0.1")
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    yield srv.server_address[1]
    srv.shutdown()
    srv.server_close()


def _same_connection(port, method, path, body):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    conn.request(method, path, body=body, headers={"Content-Type": "application/json"})
    first = conn.getresponse()
    first.read()
    conn.request("GET", "/ping")
    second = conn.getresponse()
    data = second.read()
    conn.close()
    return first.status, second.status, data


@pytest.mark.parametrize("path,expected_first,body", [
    ("/no-read", 200, b'{"reason": "x"}'),
    ("/deny", 401, b'{"reason": "x"}'),
    # 화면(JSON.stringify)은 띄어쓰기 없이 보낸다. 수정 전에는 이 모양에서 다음 요청이 정확히 501이었다
    # (g_request처럼 본문을 읽기 전에 토큰 만료 401로 끝나는 경우, WEB 확인).
    ("/deny", 401, b'{"user_id":"abc"}'),
])
def test_본문을_안_읽은_요청_뒤에도_같은_연결의_다음_요청이_정상(server, path, expected_first, body):
    first, second, data = _same_connection(server, "POST", path, body)
    assert first == expected_first
    assert second == 200, f"두 번째 요청이 {second}로 실패 (501이면 남은 본문 때문)"
    assert b"pong" in data


def test_너무_큰_본문도_서버가_멈추지_않음(server):
    # MAX_BODY(1024)보다 큰 본문은 읽지 않고 연결을 끊는다. 손님이 아직 보내는 중에 끊기면
    # 운영체제가 첫 응답까지 버릴 수 있으므로(Windows에서 자주 보임) 첫 응답은 확인하지 않는다.
    # 확인할 것은 서버가 멈추지 않고 새 연결을 계속 받는지다.
    conn = http.client.HTTPConnection("127.0.0.1", server, timeout=5)
    try:
        conn.request("POST", "/no-read", body=b"x" * 2048)
        resp = conn.getresponse()
        resp.read()
        assert resp.status == 200
    except (ConnectionError, http.client.HTTPException):
        pass
    finally:
        conn.close()
    fresh = http.client.HTTPConnection("127.0.0.1", server, timeout=5)
    fresh.request("GET", "/ping")
    assert fresh.getresponse().status == 200
    fresh.close()


def test_같은_연결의_두번째_요청은_자기_본문을_읽는다(server):
    # 수정 전에는 첫 요청의 본문이 남아 두 번째 요청이 그것을 읽고(업로드면 400 invalid multipart body),
    # 자기 본문은 연결에 남아 다음 요청이 501로 깨졌다 (11-25 업로드 첫 시도 실패 사례).
    conn = http.client.HTTPConnection("127.0.0.1", server, timeout=5)
    for body in (b"AAAA", b"BBBBBBBB"):
        conn.request("POST", "/echo", body=body, headers={"Content-Type": "application/json"})
        resp = conn.getresponse()
        assert resp.status == 200
        assert resp.read() == b'{"got": "%s"}' % body
    conn.request("GET", "/ping")
    resp = conn.getresponse()
    assert resp.status == 200, f"뒤이은 GET이 {resp.status}로 실패 (501이면 남은 본문 때문)"
    conn.close()
