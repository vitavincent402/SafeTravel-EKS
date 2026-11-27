"""keeper 화면 E2E 시험 (체험 모드).

로그인 설정(auth-config.js)이 비어 있으면 화면이 체험 모드(mock-api.js)로 열린다.
그래서 실제 클러스터·Cognito·api 없이 화면만 띄워 핵심 흐름을 자동으로 확인할 수 있다.

실행
  BASE_URL=http://localhost:8080 pytest tests/e2e -v
  E2E_HEADERS=1 이면 nginx(웹 이미지)로 띄웠을 때만 의미 있는 보안 헤더 시험도 한다.
  CHROME_PATH 가 있으면 그 크롬을 쓴다(로컬). 없으면 playwright 가 설치한 chromium(CI).
"""
import os
import re
import struct
import zlib

import pytest
from playwright.sync_api import expect

BASE_URL = os.environ.get("BASE_URL", "http://localhost:8080").rstrip("/")
HEADERS = os.environ.get("E2E_HEADERS") == "1"
POLL_WAIT = 15_000  # 화면 폴링이 10초 간격이라 상대 탭 변화는 최대 15초까지 기다린다


def tiny_png():
    """1x1 PNG. 시험용 업로드 파일."""
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    raw = b"\x00\x00\x00\x00"
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def enter(context, role_button):
    """첫 화면에서 체험 버튼을 눌러 들어간 탭을 돌려준다. 역할은 탭마다 따로 정해진다."""
    pg = context.new_page()
    pg.goto(BASE_URL + "/")
    pg.get_by_role("button", name=role_button).click()
    return pg


def traveler(context):
    pg = enter(context, "여행자로 체험하기")
    expect(pg).to_have_url(re.compile(r"/traveler\.html"))
    expect(pg.locator("#docCount")).to_have_text("2")
    expect(pg.locator("#mockbar")).to_be_visible()   # 체험 모드 안내 띠
    return pg


def guardian(context):
    pg = enter(context, "보호자로 체험하기")
    expect(pg).to_have_url(re.compile(r"/guardian\.html"))
    return pg


# ---------- 첫 화면 ----------

def test_home_shows_trial_mode(context):
    pg = context.new_page()
    pg.goto(BASE_URL + "/")
    expect(pg.get_by_role("button", name="여행자로 체험하기")).to_be_visible()
    expect(pg.get_by_role("button", name="보호자로 체험하기")).to_be_visible()
    expect(pg.locator("#loginMsg")).to_contain_text("체험 모드")


# ---------- 여행자: 서류 ----------

def test_traveler_upload_adds_one_doc(context):
    pg = traveler(context)
    pg.set_input_files("#upFile", files=[{"name": "e2e.png", "mimeType": "image/png", "buffer": tiny_png()}])
    pg.fill("#upTitle", "E2E 시험 서류")
    pg.locator('#upForm button[type="submit"]').click()
    expect(pg.locator("#docCount")).to_have_text("3")
    expect(pg.locator("#docList")).to_contain_text("E2E 시험 서류")


def test_upload_button_locks_while_uploading(context):
    """PR #31: 올리는 동안 버튼을 잠가 두 번 눌러도 한 번만 저장된다."""
    pg = traveler(context)
    # 체험 모드 업로드를 1.5초 늦춰, 실제처럼 시간이 걸리는 상황을 만든다
    pg.evaluate("""() => { const o = window.keeperMock.upload;
        window.keeperMock.upload = (u, f) => new Promise(r => setTimeout(() => r(o(u, f)), 1500)); }""")
    pg.set_input_files("#upFile", files=[{"name": "e2e.png", "mimeType": "image/png", "buffer": tiny_png()}])
    pg.fill("#upTitle", "잠금 시험")
    btn = pg.locator('#upForm button[type="submit"]')
    btn.click()
    expect(btn).to_be_disabled()
    expect(btn).to_have_text("올리는 중…")
    btn.click(force=True)                                   # 잠긴 버튼을 다시 누르고
    pg.evaluate("document.getElementById('upForm').requestSubmit()")  # 엔터 제출도 해 본다
    expect(btn).to_be_enabled(timeout=5_000)
    expect(btn).to_have_text("올리기")
    expect(pg.locator("#docCount")).to_have_text("3")        # 2 → 3, 한 개만 늘어난다


# ---------- 여행자: SOS ----------

def test_sos_then_calm(context):
    pg = traveler(context)
    expect(pg.locator("#stateBadge")).to_have_text("평소")
    pg.click("#sosBtn")
    pg.click("#sosYes")
    expect(pg.locator("#stateBadge")).to_have_text("비상")
    expect(pg.locator("#stateTitle")).to_have_text("비상 모드")
    pg.click("#calmBtn")
    pg.click("#calmYes")
    expect(pg.locator("#stateBadge")).to_have_text("평소")


# ---------- 보호자 흐름 (탭 두 개) ----------

def test_guardian_request_then_traveler_denies(context):
    t = traveler(context)
    g = guardian(context)
    g.get_by_role("button", name="열람 요청").click()
    expect(g.get_by_text("열람을 요청했어요. 사용자 응답을 기다리는 중")).to_be_visible()
    expect(t.locator("#reqText")).to_contain_text("서류 열람을 요청했어요", timeout=POLL_WAIT)
    t.click("#denyBtn")
    expect(g.get_by_text("최근 요청을 사용자가 거부했어요")).to_be_visible(timeout=POLL_WAIT)
    expect(t.locator("#stateBadge")).to_have_text("평소")   # 거부했으니 비상이 아니다


def test_guardian_views_only_in_emergency(context):
    t = traveler(context)
    g = guardian(context)
    expect(g.get_by_role("button", name="서류 열람 시작")).to_have_count(0)  # 평소에는 열람 버튼이 없다
    t.click("#sosBtn")
    t.click("#sosYes")
    start = g.get_by_role("button", name="서류 열람 시작")
    expect(start).to_be_visible(timeout=POLL_WAIT)
    start.click()
    expect(g.get_by_text("열람 중이에요")).to_be_visible()
    expect(g.get_by_role("button", name="크게 보기").first).to_be_visible()
    t.click("#calmBtn")                                      # 여행자가 해제하면
    t.click("#calmYes")
    expect(g.get_by_text("열람 중이에요")).to_have_count(0, timeout=POLL_WAIT)  # 보호자 열람이 끝난다


# ---------- 보안 헤더 (nginx로 띄웠을 때만) ----------

@pytest.mark.skipif(not HEADERS, reason="E2E_HEADERS=1 (nginx 이미지로 띄웠을 때)만")
@pytest.mark.parametrize("path", ["/", "/traveler.html", "/js/common.js", "/healthz"])
def test_security_headers(context, path):
    r = context.request.get(BASE_URL + path)
    h = {k.lower(): v for k, v in r.headers.items()}
    csp = h.get("content-security-policy", "")
    assert "default-src 'self'" in csp
    assert "frame-ancestors 'none'" in csp
    assert "object-src 'none'" in csp
    assert "max-age=31536000" in h.get("strict-transport-security", "")
    assert h.get("x-frame-options", "").upper() == "DENY"
    assert h.get("x-content-type-options", "") == "nosniff"


@pytest.mark.skipif(not HEADERS, reason="E2E_HEADERS=1 (nginx 이미지로 띄웠을 때)만")
def test_no_csp_violation_on_pages(context):
    """실제 CSP 아래에서 화면이 막히는 스크립트·스타일 없이 열리는지 본다."""
    errors = []
    pg = context.new_page()
    pg.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
    pg.goto(BASE_URL + "/")
    pg.get_by_role("button", name="여행자로 체험하기").click()
    expect(pg.locator("#docCount")).to_have_text("2")
    pg.goto(BASE_URL + "/guardian.html")
    pg.wait_for_timeout(500)
    csp = [e for e in errors if "Content Security Policy" in e or "Refused to" in e]
    assert csp == [], csp


# ---------- 부분 장애 안내 ----------

def test_partial_outage_banner(context):
    """vault만 멈추면(상태 확인은 200, 본문에 vault 오류) 안내 띠가 뜨고, 돌아오면 사라진다. 11/26 장애 훈련 반영."""
    pg = traveler(context)
    bar = pg.locator("#healthbar")
    expect(bar).to_be_hidden()
    pg.evaluate("window.keeperMock.setVaultDown(true)")
    pg.evaluate("window.kp.checkHealth()")
    expect(bar).to_be_visible()
    expect(bar).to_contain_text("서류 기능이 잠시 불안정해요")
    pg.evaluate("window.keeperMock.setVaultDown(false)")
    pg.evaluate("window.kp.checkHealth()")
    expect(bar).to_be_hidden()
    expect(pg.locator("#toast")).to_contain_text("다시 정상")


def test_partial_outage_shows_on_5xx(context):
    """서류 기능이 503을 주면 1분을 기다리지 않고 바로 안내 띠가 뜬다."""
    pg = traveler(context)
    pg.evaluate("window.keeperMock.setVaultDown(true)")
    pg.evaluate("window.keeperApi.call('GET', '/api/docs')")
    expect(pg.locator("#healthbar")).to_be_visible()
