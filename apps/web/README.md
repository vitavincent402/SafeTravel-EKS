# apps/web — SafeTravel Keeper 화면 (WEB 담당)

정적 파일(HTML·CSS·JS)을 nginx(비root uid 101, 8080 포트)로 내보낸다. `/api`는 Ingress가 api 파드로 보내므로 nginx로 오지 않는다.

## 화면

| 파일 | 화면 |
|---|---|
| `public/index.html` | 첫 화면. 로그인돼 있으면 역할에 맞는 화면으로 이동 |
| `public/traveler.html` | 여행자: 지금 상태(평소/비상), SOS, 보호자 열람 요청 띠(남은 시간 + 거부), 서류함(목록·보기·올리기) |
| `public/guardian.html` | 보호자: 지키는 사람 목록, 열람 요청(사용자 응답 대기), 비상일 때 열람 토큰으로 서류 보기(제한 시간 후 자동 닫힘) |
| `public/auth/callback.html` | Cognito 로그인 후 돌아오는 화면 |

## 로그인 (Cognito)

2.5차 SafeTravel의 `cognito.js`·`api-client.js`·`auth-callback.js`를 그대로 가져왔다(Authorization Code + PKCE, 토큰은 sessionStorage, api 요청에 `Authorization: Bearer`).
설정은 `public/js/auth-config.js`(domain / clientId / scope / redirectPath / logoutPath). 비밀값이 아니다.
새 Cognito 풀이 만들어지면 domain·clientId만 넣으면 된다. 배포 때 넣는 방법(차트 값 또는 ConfigMap)은 soc와 정한다.

## 체험 모드 (mock)

`auth-config.js`가 비어 있으면 `public/js/mock-api.js`(가짜 api)로 동작한다. db 파트의 api 목록이 나오기 전에 화면을 끝까지 만들기 위한 것이다.

- 첫 화면에서 "여행자로 / 보호자로 체험하기"를 고른다. 탭마다 역할이 따로라서, 탭 두 개로 두 역할을 열면 요청·거부·비상 전환이 서로 보인다.
- 시간: 요청 대기 60초, 열람 15분(임시값). 브라우저 콘솔에서 `localStorage.setItem("keeper.mock.fast","1")`이면 10초 / 90초.
- 기본 샘플 서류는 캐릭터 "모험이"의 가상 여권·보험증(`public/img/sample-*.png`, SAMPLE 표시). 실제 개인 서류는 올리지 않는다.

화면 코드는 `public/js/keeper-api.js` 하나로만 api를 부른다. 진짜 api로 바뀌어도 화면 코드는 그대로이고, 주소·응답 모양이 확정되면 `mock-api.js`와 화면 스크립트만 맞춘다.

## 화면이 쓰는 api (db 파트에 보낸 초안, 확정 전)

| 요청 | 응답 |
|---|---|
| `GET /api/me` | `{name, role: "user"/"guardian", emergency, emergency_since, emergency_reason}` |
| `GET /api/docs` | `[{id, title, uploaded_at}]` |
| `POST /api/docs` (multipart: title, file) | `{id}` |
| `GET /api/docs/{id}` | 파일 |
| `POST /api/sos` | `{emergency: true}` |
| `GET /api/requests/pending` | `{request_id, guardian_name, expires_at}` 또는 204 |
| `POST /api/requests/{id}/deny` | `{denied: true}` |
| `GET /api/guardian/travelers` | `[{user_id, name, emergency, emergency_since, emergency_reason, request: {request_id, status, wait_until} 또는 null}]` |
| `POST /api/guardian/requests` `{user_id}` | `{request_id, wait_until}` |
| `POST /api/guardian/view-token` `{user_id}` | `{view_token, expires_at}` |
| `GET /api/guardian/travelers/{user_id}/docs` (머리말 `X-View-Token`) | `[{id, title, uploaded_at}]` |
| `GET /api/guardian/docs/{id}` (머리말 `X-View-Token`) | 파일 |

오류는 `{"error": "..."}`. 401 로그인 필요, 403 권한 없음, 404 없음, 409 지금 상태에서 불가.
남은 시간은 화면에 고정하지 않고 서버의 `expires_at`·`wait_until`(UTC) 기준으로 센다. 보호자 요청 알림은 5초마다 확인(폴링)한다.

## 보안 (WEB 담당 통제)

- `default.conf` 보안 헤더: CSP(우리 서버 스크립트·스타일만, 인라인 스크립트 금지, 외부 연결은 Cognito만), X-Frame-Options DENY, nosniff, Referrer-Policy no-referrer, Permissions-Policy. XSS를 WAF와 화면 양쪽에서 막는 이중 방어
- 서버에서 온 글자는 모두 `textContent`로 넣는다(HTML로 해석하지 않음)
- 화면 파일은 root 소유로 두고 nginx(101)는 읽기만 한다. nginx 버전은 숨긴다(`server_tokens off`)
- 규칙(README): 8080, `/healthz` 200, 비root, 쓰기는 /tmp만, Trivy HIGH·CRITICAL 통과
