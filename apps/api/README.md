# api (앱·데이터 담당)

## 지금 되는 것
- `GET /api/me`: 화면이 보낸 Cognito **ID 토큰**(`Authorization: Bearer <ID 토큰>`)을 확인하고,
  처음 로그인한 사람이면 users table에 행을 만든 뒤 `{id, email, name, role}`을 돌려준다.
- `role`: 누군가의 보호자로 등록되어 있으면 `guardian`, 아니면 `user` (임시 규칙)
- api가 켜질 때 `schema.sql`로 table 6개를 만든다 (이미 있으면 넘어감, 파드 2개가 동시에 실행해도 잠금으로 하나씩).

## 파일
| 파일 | 하는 일 |
|---|---|
| `auth.py` | 토큰 확인: 서명, 만료, 발급자(우리 풀), 대상(우리 앱 클라이언트), 종류(ID 토큰) |
| `users.py` | Cognito 고유 번호(sub)로 사용자 찾기/만들기, 역할 계산 |
| `db.py` | DB 연결 (비밀번호는 Secrets Manager에서 IRSA로 직접 읽음), table 만들기 |
| `main.py` | 서버와 주소(`/healthz`, `/api/healthz`, `/api/me`) |
| `schema.sql` | table 6개 (임시) |

## 응답 코드
| 코드 | 언제 |
|---|---|
| 200 | 정상 |
| 401 | 토큰 없음, 위조, 만료, 다른 풀·다른 앱, access 토큰 |
| 403 | 이메일이 확인되지 않은 계정 |
| 409 | 같은 이메일을 다른 Cognito 계정이 이미 씀 |
| 503 | Cognito 설정 없음, 공개 키를 못 받음, DB 준비 안 됨 |

## 환경 변수
`COGNITO_USER_POOL_ID`, `COGNITO_CLIENT_ID`, `AWS_REGION`, `DB_HOST`, `DB_NAME`, `DB_SECRET_ARN`, `VAULT_URL`, `PORT`
(Cognito 두 값은 차트 `cognito.userPoolId`, `cognito.clientId`에서 들어옴. Terraform이 채움)

## 시험
```
pip install -r requirements.txt pytest
python -m pytest -q tests
```
