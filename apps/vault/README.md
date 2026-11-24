# vault (앱·데이터 담당)

서류를 KMS 봉투 암호화로 저장하고, 조건이 맞을 때만 풀어 준다. api만 부를 수 있다 (NetworkPolicy + 요청 서명).

## 봉투 암호화 (`crypto.py`)
1. 서류마다 KMS `GenerateDataKey`로 데이터 키(AES-256)를 받는다.
2. 데이터 키로 서류를 AES-256-GCM 암호화 → S3 `documents/{주인}/{서류}` 에 저장 (버킷 기본 SSE-KMS도 한 번 더 적용).
3. KMS로 암호화된 데이터 키만 DB `documents.encrypted_data_key`에 저장. 평문 키는 저장하지 않음.
4. 암호화 문맥 `{document_id, owner_id}`: 다른 서류의 키로는 풀리지 않고, CloudTrail에 어느 서류인지 남음.
5. 삭제: S3 객체 삭제 + DB의 암호화된 키를 비움 (감사 기록 때문에 행은 남김).

## 열람 조건 (`rules.access_denied_reason`)
- 서류 주인: 항상 허용
- 다른 사람: **보호자** + **비상 상태** + **유효한 열람 토큰**(이 보호자·이 주인 것, 15분 안, 취소 안 됨)
- 허용과 거부를 모두 `audit_logs`에 남김

## 주소 (api가 서명해서 부름)
`GET /healthz`, `POST /documents`, `GET /documents[?owner_id=]`, `GET /documents/{id}`, `DELETE /documents/{id}`

## 요청 서명 (`internal_auth.py`)
api와 vault가 Secrets Manager `keeper/app`의 `token_signing_key`를 같이 쓴다.
HMAC-SHA256(방식, 경로, 요청한 사람, 시각, 본문 해시, 열람 토큰 해시). 시각 차이 60초 넘으면 거부.

## 환경 변수 (차트가 넣어 줌)
`AWS_REGION`, `DB_HOST`, `DB_NAME`, `DB_SECRET_ARN`, `APP_SECRET_ARN`, `DOC_BUCKET`, `KMS_KEY_ARN`, `PORT`

시험은 `apps/api/tests/test_flow.py`가 api와 vault를 함께 띄워서 한다.
