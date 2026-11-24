# api (앱·데이터 담당)

화면이 부르는 서버. 로그인 확인, 보호자, 비상 상태, 열람 토큰을 처리하고, 서류 요청은 서명해서 vault로 넘긴다.
서류를 직접 암호화하거나 풀지 않는다 (api 역할에는 KMS·S3 권한이 없음).

## 주소 (화면·문서 담당의 주소 표와 같음)
인증: 모든 /api 요청에 `Authorization: Bearer <Cognito 액세스 토큰>` (ID 토큰도 받음).
액세스 토큰에는 이메일이 없어서, 처음 로그인한 사람만 Cognito userInfo에 한 번 물어본다.
오류는 `{"error": "..."}`, 시각은 UTC ISO (`2026-11-24T05:20:00Z`).

| 주소 | 하는 일 |
|---|---|
| `GET /api/me` | `{id, email, name, role, emergency, emergency_since, emergency_reason}` |
| `GET /api/docs` | `[{id, title, uploaded_at, content_type}]` |
| `POST /api/docs` (multipart: title, file) | `{id}`. PNG·JPEG·WEBP·PDF만, 최대 5MB (종류는 파일 내용으로 판단) |
| `GET /api/docs/{id}` | 파일 |
| `DELETE /api/docs/{id}` | 삭제 **(추가)** |
| `POST /api/sos` | `{emergency: true}`. 이미 비상이면 409 |
| `POST /api/sos/cancel` | `{emergency: false}`. 비상 해제, 대기 요청 취소, 열람 토큰 모두 취소 **(추가)** |
| `GET /api/requests/pending` | `{request_id, guardian_name, expires_at}` / 없으면 204 |
| `POST /api/requests/{id}/deny` | `{denied: true}`. 시간이 지났으면 409 |
| `GET /api/guardian/travelers` | `[{user_id, name, emergency, emergency_since, emergency_reason, request}]` |
| `POST /api/guardian/requests {user_id}` | `{request_id, wait_until}`. 이미 대기 중·이미 비상이면 409 |
| `POST /api/guardian/view-token {user_id}` | `{view_token, expires_at}`. 비상 아니면 403 |
| `GET /api/guardian/travelers/{user_id}/docs` (X-View-Token) | `[{id, title, uploaded_at, content_type}]` |
| `GET /api/guardian/docs/{id}` (X-View-Token) | 파일 |
| `GET /api/guardians`, `POST /api/guardians {email}`, `DELETE /api/guardians/{user_id}` | 보호자 관리 **(추가)** |

request.status: `pending`, `denied`, `timeout`(1분 무응답 → 자동 비상), `cancelled`(여행자가 SOS 또는 해제)
403 error 값: `not_guardian`, `not_emergency`, `no_view_token`, `invalid_view_token`, `not_owner`
role: 누군가의 보호자로 등록되어 있으면 `guardian`, 아니면 `user` (DB 기준, Cognito 그룹 안 씀)

## 파일
| 파일 | 하는 일 |
|---|---|
| `main.py` | 주소별 처리 |
| `auth.py` | Cognito ID 토큰 확인 (서명, 만료, 발급자, 앱 클라이언트, 토큰 종류) |
| `users.py` | 토큰 내용 → 사용자 정보, 역할 계산 |
| `vault_client.py` | vault로 서명한 요청 보내기 |
| `schema.sql` | table 7개 (임시). api가 켜질 때 적용 |
| `internal_auth.py` `rules.py` `web.py` `db.py` `store.py` | **vault와 같은 내용의 공통 파일.** 고치면 `apps/vault`에도 복사 (`tests/test_shared.py`가 검사) |

## 환경 변수 (차트가 넣어 줌)
`COGNITO_USER_POOL_ID`, `COGNITO_CLIENT_ID`, `AWS_REGION`, `DB_HOST`, `DB_NAME`, `DB_SECRET_ARN`, `APP_SECRET_ARN`, `VAULT_URL`, `PORT`
선택: `VIEW_TOKEN_MINUTES`(기본 15),
`REQUEST_WAIT_SECONDS`(기본 60), `SEED_JSON`(시험 데이터 `{"users":[{email,name,cognito_sub}],"guardians":[{owner_email,guardian_email}]}`)

## 시험
```
pip install -r requirements.txt pytest
python -m pytest -q tests                      # 로그인·흐름·공통 파일 40개
PGHOST=... PGUSER=... PGDATABASE=... python tests/check_sql.py   # 모든 SQL을 실제 PostgreSQL에서 실행
```
