-- grants.sql : DB 계정별 최소 권한 (api·vault·감사 조회)
-- 근거: apps/api/store.py, apps/vault/store.py 의 SQL 문
--
-- 실행 순서 (인프라 구축 Job, 매 구축마다):
--   1. 마스터: 계정 생성 (비밀번호는 Secrets Manager 값, 이 파일에 적지 않음)
--        keeper_migrate, keeper_api, keeper_vault : LOGIN + 비밀번호
--        keeper_audit_ro : LOGIN, 비밀번호 없음, GRANT rds_iam TO keeper_audit_ro (IAM 인증)
--      마스터: REVOKE CREATE ON SCHEMA public FROM PUBLIC;
--              GRANT USAGE, CREATE ON SCHEMA public TO keeper_migrate;
--              GRANT USAGE ON SCHEMA public TO keeper_api, keeper_vault, keeper_audit_ro;
--              GRANT CONNECT ON DATABASE <DB 이름> TO 위 4개 계정;
--   2. keeper_migrate: schema.sql 실행 (테이블 소유자가 keeper_migrate가 됨)
--   3. keeper_migrate: 이 파일 실행
--   4. api 환경 변수 SCHEMA_APPLY=off (api는 테이블을 만들지 않고 있는지만 확인)
--
-- 규칙: schema.sql에 테이블을 추가하면 이 파일의 GRANT도 같은 PR에 추가한다.
-- ALTER DEFAULT PRIVILEGES는 쓰지 않는다 (테이블 단위로만 줄 수 있어 칸 단위 제한이 풀림).

-- ---------- keeper_api ----------
GRANT SELECT, INSERT ON users TO keeper_api;
GRANT UPDATE (email, name) ON users TO keeper_api;                                   -- login
GRANT SELECT, INSERT, DELETE ON guardians TO keeper_api;
GRANT UPDATE (status, accepted_at) ON guardians TO keeper_api;                       -- 보호자 수락
GRANT SELECT, INSERT ON emergency_states TO keeper_api;
GRANT UPDATE (status, trigger_source, changed_at) ON emergency_states TO keeper_api; -- set_emergency
GRANT SELECT, INSERT ON access_requests TO keeper_api;
GRANT UPDATE (status, responded_at) ON access_requests TO keeper_api;                -- deny/expire/cancel
GRANT SELECT, INSERT ON view_tokens TO keeper_api;
GRANT UPDATE (revoked_at) ON view_tokens TO keeper_api;                              -- revoke_view_tokens
GRANT INSERT ON audit_logs TO keeper_api;                                            -- 쓰기만
-- documents: api는 사용하지 않음

-- ---------- keeper_vault ----------
GRANT SELECT, INSERT ON documents TO keeper_vault;
GRANT UPDATE (deleted_at, encrypted_data_key) ON documents TO keeper_vault;          -- mark_document_deleted
GRANT SELECT ON guardians TO keeper_vault;                                           -- is_guardian
GRANT SELECT, INSERT ON emergency_states TO keeper_vault;
GRANT UPDATE (status, trigger_source, changed_at) ON emergency_states TO keeper_vault;
GRANT SELECT ON access_requests TO keeper_vault;
GRANT UPDATE (status) ON access_requests TO keeper_vault;                            -- expire_requests
GRANT SELECT ON view_tokens TO keeper_vault;                                         -- valid_view_token
GRANT INSERT ON audit_logs TO keeper_vault;                                          -- 쓰기만
-- users: vault는 사용하지 않음

-- ---------- keeper_audit_ro (SOC 감사 로그 조회) ----------
GRANT SELECT ON audit_logs TO keeper_audit_ro;

-- ---------- 적용 후 확인 (모두 permission denied여야 정상, 지워지지 않게 ROLLBACK) ----------
-- BEGIN; SET LOCAL ROLE keeper_api;   SELECT 1 FROM audit_logs LIMIT 1; ROLLBACK;
-- BEGIN; SET LOCAL ROLE keeper_api;   SELECT 1 FROM documents LIMIT 1;  ROLLBACK;
-- BEGIN; SET LOCAL ROLE keeper_vault; SELECT 1 FROM users LIMIT 1;      ROLLBACK;
-- BEGIN; SET LOCAL ROLE keeper_vault; DELETE FROM audit_logs WHERE false; ROLLBACK;
