"""E2E 시험 공용 준비: 브라우저 하나를 열어 두고, 시험마다 새 컨텍스트(새 저장소)를 쓴다.
실패한 시험은 열린 탭을 모두 캡처해 E2E_SHOTS 폴더에 남긴다(CI에서 결과물로 올림)."""
import os

import pytest
from playwright.sync_api import sync_playwright

SHOTS = os.environ.get("E2E_SHOTS", "tests/e2e/shots")


@pytest.fixture(scope="session")
def browser():
    with sync_playwright() as p:
        kw = {"executable_path": os.environ["CHROME_PATH"]} if os.environ.get("CHROME_PATH") else {}
        b = p.chromium.launch(**kw)
        yield b
        b.close()


@pytest.fixture()
def context(browser, request):
    ctx = browser.new_context(viewport={"width": 1280, "height": 900})
    yield ctx
    failed = getattr(request.node, "rep_call", None)
    if failed is not None and failed.failed:
        os.makedirs(SHOTS, exist_ok=True)
        for i, pg in enumerate(ctx.pages):
            pg.screenshot(path=os.path.join(SHOTS, f"{request.node.name}-{i}.png"), full_page=True)
    ctx.close()


@pytest.hookimpl(hookwrapper=True, tryfirst=True)
def pytest_runtest_makereport(item, call):
    outcome = yield
    rep = outcome.get_result()
    setattr(item, "rep_" + rep.when, rep)


