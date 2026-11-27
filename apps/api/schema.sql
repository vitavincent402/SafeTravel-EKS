-- schema.sql (임시) : SafeTravel Keeper table 7개
-- PostgreSQL 16 기준. 여러 번 실행해도 안전하도록 IF NOT EXISTS를 씀.
-- api가 시작할 때 한 번에 실행함 (동시 실행은 db.py의 잠금이 막음).

-- 1. 사용자: Cognito로 로그인하는 사람 모두 (서류 주인과 보호자). 역할 항목은 두지 않음. 비밀번호는 Cognito가 보관하므로 여기에 두지 않음.
CREATE TABLE IF NOT EXISTS users (
    id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    email          text        NOT NULL UNIQUE,   -- Cognito 로그인 이메일(토큰에서 가져옴), 같은 이메일은 하나만
    name           text        NOT NULL,
    cognito_sub    text        NOT NULL UNIQUE,   -- Cognito가 사용자마다 주는 고유 번호
    created_at     timestamptz NOT NULL DEFAULT now()
);

-- 2. 보호자 관계: 한 줄 = 'owner_id의 보호자가 guardian_id'
CREATE TABLE IF NOT EXISTS guardians (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id     uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    guardian_id  uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    status       text        NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted')),  -- 보호자가 수락해야 accepted
    created_at   timestamptz NOT NULL DEFAULT now(),
    accepted_at  timestamptz,
    UNIQUE (owner_id, guardian_id),
    CHECK (owner_id <> guardian_id)
);
-- 11-27 보호자 수락 단계: 예전 DB(복원)에 열이 없으면 추가한다. 이미 있던 관계는 수락된 것으로 둔다
ALTER TABLE guardians ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'accepted';
ALTER TABLE guardians ADD COLUMN IF NOT EXISTS accepted_at timestamptz;
ALTER TABLE guardians ALTER COLUMN status SET DEFAULT 'pending';
-- 예전 DB 경로에는 위 CREATE TABLE의 CHECK가 없으므로 같은 이름(PostgreSQL 기본 이름)으로 한 번만 추가
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'guardians_status_check') THEN
        ALTER TABLE guardians ADD CONSTRAINT guardians_status_check CHECK (status IN ('pending', 'accepted'));
    END IF;
END $$;

-- 3. 서류: 파일 자체는 S3에, 여기에는 정보만 저장
CREATE TABLE IF NOT EXISTS documents (
    id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id            uuid        NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    doc_type            text        NOT NULL,
    file_name           text        NOT NULL,
    content_type        text        NOT NULL,       -- 파일 내용으로 판단한 종류 (image/png 등)
    s3_key              text        NOT NULL UNIQUE,
    encrypted_data_key  bytea       NOT NULL,
    uploaded_at         timestamptz NOT NULL DEFAULT now(),
    deleted_at          timestamptz                     -- 삭제한 시각. 감사 기록 때문에 행은 남기고 데이터 키는 비움
);

-- 4. 비상 상태: 사용자당 한 줄
--    status: normal(평상) / emergency(비상)
--    trigger_source: sos(사용자가 SOS) / auto(열람 요청에 1분 무응답으로 자동 전환)
CREATE TABLE IF NOT EXISTS emergency_states (
    user_id         uuid        PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    status          text        NOT NULL DEFAULT 'normal' CHECK (status IN ('normal', 'emergency')),
    trigger_source  text        CHECK (trigger_source IN ('sos', 'auto')),
    changed_at      timestamptz NOT NULL DEFAULT now()       -- 상태가 바뀐 시각 (비상 시작 시각)
);

-- 4-1. 열람 요청: 보호자가 요청하면 pending, 여행자가 거절하면 denied,
--      wait_until까지 응답이 없으면 timeout(→ 자동 비상), 여행자가 SOS를 해제하면 cancelled
CREATE TABLE IF NOT EXISTS access_requests (
    id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id      uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,   -- 여행자(서류 주인)
    guardian_id   uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,   -- 요청한 보호자
    status        text        NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending', 'denied', 'timeout', 'cancelled')),
    requested_at  timestamptz NOT NULL DEFAULT now(),
    wait_until    timestamptz NOT NULL,                     -- 이 시각까지 응답 없으면 자동 비상 (요청 + 1분)
    responded_at  timestamptz,                              -- 거절·취소한 시각
    CHECK (owner_id <> guardian_id)
);
-- 여행자 한 명에게 대기 중인 요청은 하나만
CREATE UNIQUE INDEX IF NOT EXISTS uq_access_requests_one_pending
    ON access_requests (owner_id) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS idx_access_requests_owner_guardian ON access_requests (owner_id, guardian_id);

-- 5. 열람 토큰: 토큰 값 자체가 아니라 해시를 저장
CREATE TABLE IF NOT EXISTS view_tokens (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    token_hash   text        NOT NULL UNIQUE,
    guardian_id  uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    owner_id     uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    expires_at   timestamptz NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    revoked_at   timestamptz
);

-- 6. 감사 기록: 허용과 거부를 모두 남김
CREATE TABLE IF NOT EXISTS audit_logs (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    occurred_at  timestamptz NOT NULL DEFAULT now(),
    actor_id     uuid        REFERENCES users(id) ON DELETE RESTRICT,
    document_id  uuid        REFERENCES documents(id) ON DELETE RESTRICT,
    action       text        NOT NULL,
    result       text        NOT NULL CHECK (result IN ('allowed', 'denied')),
    deny_reason  text
);

CREATE INDEX IF NOT EXISTS idx_guardians_guardian   ON guardians (guardian_id);
CREATE INDEX IF NOT EXISTS idx_documents_owner      ON documents (owner_id);
CREATE INDEX IF NOT EXISTS idx_view_tokens_lookup   ON view_tokens (guardian_id, owner_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_time      ON audit_logs (occurred_at);
