"""store.py의 모든 SQL을 실제 PostgreSQL에서 실행해 본다 (pytest가 아니라 따로 실행).

사용: PGHOST=... PGUSER=... PGDATABASE=... python tests/check_sql.py
- psql 명령이 있어야 한다. 빈 DB에 schema.sql을 적용한 뒤
- 모든 SQL을 PREPARE(문법·열 이름 검사)하고
- 실제 흐름(로그인, 보호자, 비상, 토큰, 서류, 삭제, 감사, 시험 데이터)을 실행해 결과를 확인한다.
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
from store import SQL  # noqa: E402

SCHEMA = os.path.join(os.path.dirname(HERE), "schema.sql")


def psql(sql, expect_error=False):
    r = subprocess.run(["psql", "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1", "-c", sql],
                       capture_output=True, text=True)
    if expect_error:
        assert r.returncode != 0, f"오류가 나야 하는데 성공함: {sql}"
        return r.stderr
    assert r.returncode == 0, f"{sql}\n{r.stderr}"
    return r.stdout.strip()


def numbered(sql):
    n = iter(range(1, 100))
    return re.sub(r"%s", lambda _: f"${next(n)}", sql)


def lit(v):
    if v is None:
        return "NULL"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, bytes):
        return "'\\x" + v.hex() + "'::bytea"
    return "'" + str(v).replace("'", "''") + "'"


def run(name, *params):
    """SQL[name]을 PREPARE 하고 EXECUTE 한다 (psycopg가 하는 것과 같은 방식)."""
    args = ", ".join(lit(p) for p in params)
    return psql(f"PREPARE q AS {numbered(SQL[name])}; EXECUTE q{'(' + args + ')' if params else ''};")


def main():
    psql("DROP SCHEMA public CASCADE; CREATE SCHEMA public;")
    with open(SCHEMA, encoding="utf-8") as f:
        schema = f.read()
    subprocess.run(["psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-c", schema], check=True, capture_output=True)
    subprocess.run(["psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-c", schema], check=True, capture_output=True)
    print("schema.sql 두 번 적용 OK, table 수:",
          psql("select count(*) from information_schema.tables where table_schema='public'"))

    for name, sql in SQL.items():
        psql(f"PREPARE q AS {numbered(sql)};")
    print(f"SQL {len(SQL)}개 PREPARE OK")

    now = "2026-11-24 05:00:00+00"
    later = "2026-11-24 05:15:00+00"
    owner = run("login", "owner@example.com", "주인", "sub-o").split("|")
    guardian = run("login", "guardian@example.com", "보호자", "sub-g").split("|")
    assert owner[3] == "f"
    again = run("login", "owner@example.com", "이름바뀜", "sub-o").split("|")
    assert again[0] == owner[0] and again[2] == "이름바뀜", again
    err = psql(f"PREPARE q AS {numbered(SQL['login'])}; EXECUTE q('owner@example.com','x','sub-x');",
               expect_error=True)
    assert "users_email_key" in err                             # 같은 이메일, 다른 계정 → 거부 (api는 409)
    o, g = owner[0], guardian[0]
    assert run("user_by_email", "guardian@example.com").split("|")[0] == g
    assert run("add_guardian", o, g) != ""
    assert run("add_guardian", o, g) == ""                     # 두 번째는 아무것도 안 넣음
    psql(f"INSERT INTO guardians(owner_id, guardian_id) VALUES ('{o}','{o}')", expect_error=True)  # 자기 자신
    assert run("login", "guardian@example.com", "보호자", "sub-g").split("|")[3] == "t"  # 역할 guardian
    assert run("is_guardian", o, g) == "t" and run("is_guardian", g, o) == "f"
    assert run("my_guardians", o).split("|")[0] == g and run("guarding", g).split("|")[0] == o

    assert run("user_by_sub", "sub-g").split("|")[0] == g and run("user_by_sub", "nobody") == ""
    assert run("get_emergency", o) == ""
    run("set_emergency", o, "emergency", "sos", now)
    assert run("get_emergency", o).split("|")[:2] == ["emergency", "sos"]
    run("set_emergency", o, "normal", None, now)
    psql(f"PREPARE q AS {numbered(SQL['set_emergency'])}; EXECUTE q('{o}','pending',NULL,'{now}');",
         expect_error=True)                                     # 정해진 상태 값만 (normal, emergency)

    # 열람 요청: 만들기 → 대기 하나만 → 대기 조회 → 시간 지나면 timeout
    wait = "2026-11-24 05:01:00+00"
    req = run("create_request", o, g, wait).split("|")[0]
    err = psql(f"PREPARE q AS {numbered(SQL['create_request'])}; EXECUTE q('{o}','{g}','{wait}');",
               expect_error=True)
    assert "uq_access_requests_one_pending" in err              # 대기 중 요청은 하나만 (api는 409)
    assert run("pending_request", o, now).split("|")[:2] == [req, "보호자"]
    assert run("latest_request", o, g).split("|")[:2] == [req, "pending"]
    assert run("get_request", req).split("|")[2] == "pending"
    assert run("expire_requests", o, now) == ""                # 아직 1분 안 지남
    assert run("expire_requests", o, wait) != ""               # 1분 지남 → timeout
    assert run("latest_request", o, g).split("|")[1] == "timeout"
    assert run("pending_request", o, wait) == ""
    # 거절: 시간 안에만
    req2 = run("create_request", o, g, wait).split("|")[0]
    assert run("deny_request", now, req2, g, now) == ""        # 다른 사람(보호자)은 거절 못 함
    run("deny_request", now, req2, o, now)
    assert run("get_request", req2).split("|")[2] == "denied"
    req3 = run("create_request", o, g, wait).split("|")[0]
    run("cancel_requests", now, o)
    assert run("get_request", req3).split("|")[2] == "cancelled"
    psql(f"INSERT INTO access_requests(owner_id, guardian_id, wait_until) VALUES ('{o}','{o}','{wait}')",
         expect_error=True)                                     # 자기 자신에게 요청 불가

    run("insert_view_token", "hash1", g, o, later)
    assert run("valid_view_token", "hash1", g, o, now) == "t"
    assert run("valid_view_token", "hash1", g, o, later) == "f"   # 만료 시각이 되면 무효
    assert run("valid_view_token", "hash1", o, o, now) == "f"     # 다른 사람
    assert run("revoke_view_tokens", now, o) == ""
    assert run("valid_view_token", "hash1", g, o, now) == "f"     # 취소됨

    doc = "11111111-2222-3333-4444-555555555555"
    run("insert_document", doc, o, "여권", "p.png", "image/png", f"documents/{o}/{doc}", b"\x01\x02")
    row = run("get_document", doc).split("|")
    assert row[1] == o and row[4] == "image/png" and row[6] == "\\x0102" and row[8] == ""
    assert run("list_documents", o).split("|")[0] == doc
    run("audit", g, doc, "document_view", "allowed", None)
    run("audit", g, None, "document_view", "denied", "not_emergency")
    run("mark_document_deleted", now, b"", doc)
    row = run("get_document", doc).split("|")
    assert row[6] == "\\x" and row[8] != ""                       # 키 비움, 삭제 시각 있음
    assert run("list_documents", o) == ""
    assert psql("select count(*) from documents") == "1"          # 감사 기록 때문에 행은 남음
    psql(f"PREPARE q AS {numbered(SQL['audit'])}; EXECUTE q(NULL,NULL,'x','maybe',NULL);", expect_error=True)
    assert run("remove_guardian", o, g) == "" and run("is_guardian", o, g) == "f"

    run("seed_user", "seed@example.com", "시드", "sub-seed")
    run("seed_user", "seed@example.com", "시드", "sub-seed")       # 두 번 넣어도 오류 없음
    run("seed_guardian", "owner@example.com", "seed@example.com")
    run("seed_guardian", "owner@example.com", "seed@example.com")
    assert psql("select count(*) from guardians") == "1"
    print("실행 흐름 확인 OK (로그인, 보호자, 비상, 열람 요청, 토큰, 서류, 삭제, 감사, 시험 데이터)")


if __name__ == "__main__":
    main()
