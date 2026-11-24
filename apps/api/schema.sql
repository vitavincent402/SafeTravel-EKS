-- schema.sql (임시) : SafeTravel Keeper table 6개
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
    created_at   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (owner_id, guardian_id),
    CHECK (owner_id <> guardian_id)
);

-- 3. 서류: 파일 자체는 S3에, 여기에는 정보만 저장
CREATE TABLE IF NOT EXISTS documents (
    id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id            uuid        NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    doc_type            text        NOT NULL,
    file_name           text        NOT NULL,
    s3_key              text        NOT NULL UNIQUE,
    encrypted_data_key  bytea       NOT NULL,
    uploaded_at         timestamptz NOT NULL DEFAULT now()
);

-- 4. 비상 상태: 사용자당 한 줄
CREATE TABLE IF NOT EXISTS emergency_states (
    user_id         uuid        PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    status          text        NOT NULL DEFAULT 'normal'
                    CHECK (status IN ('normal', 'pending', 'emergency')),
    requested_by    uuid        REFERENCES users(id),
    requested_at    timestamptz,
    changed_at      timestamptz NOT NULL DEFAULT now(),
    trigger_source  text        CHECK (trigger_source IN ('sos', 'auto'))
);

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
