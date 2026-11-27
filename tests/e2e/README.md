# 화면 E2E 시험 (web)

web 이미지를 배포와 같은 Dockerfile로 빌드해 nginx로 띄우고, 브라우저(Playwright, Chromium)로 핵심 흐름을 자동으로 확인합니다.
로그인 설정(auth-config.js)이 비어 있으면 화면이 체험 모드(mock-api.js)로 열리기 때문에, 클러스터·Cognito·api 없이 돌아갑니다.

## 무엇을 보나

| 시험 | 확인하는 것 | 관련 PR |
|---|---|---|
| test_home_shows_trial_mode | 첫 화면에 체험 버튼 두 개 | #4 |
| test_traveler_upload_adds_one_doc | 서류 올리기 → 서류함에 1개 추가 | #4 |
| test_upload_button_locks_while_uploading | 올리는 동안 버튼 잠금, 두 번 눌러도 1개만 저장 | #31 |
| test_sos_then_calm | SOS → 비상 모드 → 해제 → 평소 | #4 |
| test_guardian_request_then_traveler_denies | 보호자 열람 요청 → 여행자 알림 → 거부 → 보호자에게 거부 표시 | #4, #13 |
| test_guardian_views_only_in_emergency | 평소엔 열람 버튼 없음 → SOS 뒤 열람 → 여행자 해제 시 열람 종료 | #4 |
| test_security_headers (4개 주소) | CSP(default-src·frame-ancestors·object-src), HSTS 1년, X-Frame-Options, nosniff | #4, #11 |
| test_no_csp_violation_on_pages | 실제 CSP 아래에서 화면이 막히는 스크립트·스타일 없이 열림 | #11 |
| test_invite_accept_updates_traveler_without_reload | 자동 비상 규칙(서버 대기 시간) 동의 없이는 초대 불가 → 수락 전 이름 숨김 → 보호자 동의·수락 → 여행자 화면이 새로고침 없이 "보호자"로 바뀌고 알림 | #41, 이번 PR |

보안 헤더 시험 두 개는 nginx로 띄웠을 때만 의미가 있어서 `E2E_HEADERS=1`일 때만 돕니다.

## 언제 도나

`.github/workflows/web-e2e.yml`: `apps/web/**`나 `tests/e2e/**`를 바꾸는 PR과 main 병합 때 자동으로 돕니다. AWS 권한은 쓰지 않습니다.
실패하면 열린 탭 캡처와 nginx 로그가 결과물(e2e-shots)로 올라갑니다.

## 직접 돌리기

```
cd apps/web/public && python3 -m http.server 8080      # 다른 창
pip install playwright pytest && python -m playwright install chromium
BASE_URL=http://localhost:8080 pytest tests/e2e -v
```
로컬 크롬을 쓰려면 `CHROME_PATH=<크롬 경로>`를 더합니다.

## 회귀를 잡는지 확인

PR #31 이전 화면 코드로 띄우면 test_upload_button_locks_while_uploading이 실패하는 것을 확인했습니다(버튼이 잠기지 않음).
