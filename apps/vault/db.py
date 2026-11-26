"""DB 연결과 비밀값 읽기 (api와 vault에 같은 파일이 있음).

- 비밀번호·키는 환경 변수에 없다. 위치(ARN)만 받고 파드가 IRSA 권한으로 Secrets Manager에서 직접 읽는다.
- RDS가 비밀번호를 주기적으로 바꾸므로, 연결 실패 시 한 번 다시 읽는다.
- table 만들기는 api만 한다. 파드 2개가 동시에 실행해도 DB 잠금(advisory lock)으로 하나씩.
"""
import json
import os
import threading

SCHEMA_LOCK_ID = 7_301_001
SCHEMA_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "schema.sql")


def read_secret_json(secret_arn, region):
    import boto3
    sm = boto3.client("secretsmanager", region_name=region)
    return json.loads(sm.get_secret_value(SecretId=secret_arn)["SecretString"])


def load_signing_key(app_secret_arn, region):
    """api↔vault 서명 키 (Terraform이 만든 keeper/app 비밀값의 token_signing_key)."""
    return read_secret_json(app_secret_arn, region)["token_signing_key"].encode()


def make_connect(host, dbname, secret_arn, region):
    """호출하면 새 DB 연결을 돌려주는 함수를 만든다."""
    import psycopg

    cache = {}
    lock = threading.Lock()

    def load(force=False):
        with lock:
            if force or "value" not in cache:
                cache["value"] = read_secret_json(secret_arn, region)
            return cache["value"]

    def open_conn(secret):
        return psycopg.connect(host=host, dbname=dbname, user=secret["username"],
                               password=secret["password"], sslmode="require", connect_timeout=5)

    def connect():
        try:
            return open_conn(load())
        except psycopg.OperationalError:
            return open_conn(load(force=True))

    return connect


def apply_schema(connect, path=SCHEMA_PATH):
    with open(path, encoding="utf-8") as f:
        sql = f.read()
    with connect() as conn:
        conn.execute("SELECT pg_advisory_xact_lock(%s)", (SCHEMA_LOCK_ID,))
        conn.execute(sql)


REQUIRED_TABLES = ("users", "guardians", "documents", "emergency_states",
                   "access_requests", "view_tokens", "audit_logs")


def missing_tables(connect):
    """schema.sql의 table 중 없는 것 목록. 만들지는 않는다 (table 만들 권한이 없는 계정용)."""
    names = ["public." + t for t in REQUIRED_TABLES]
    with connect() as conn:
        row = conn.execute("SELECT " + ", ".join(["to_regclass(%s)"] * len(names)), names).fetchone()
    return [t for t, found in zip(REQUIRED_TABLES, row) if found is None]


class PgBase:
    """SQL 실행 도우미. 결과를 dict로 돌려준다."""

    def __init__(self, connect):
        self._connect = connect

    def _rows(self, sql, params=()):
        with self._connect() as conn, conn.cursor() as cur:
            cur.execute(sql, params)
            if cur.description is None:
                return []
            names = [d.name for d in cur.description]
            return [dict(zip(names, row)) for row in cur.fetchall()]

    def _one(self, sql, params=()):
        rows = self._rows(sql, params)
        return rows[0] if rows else None

    def _value(self, sql, params=()):
        row = self._one(sql, params)
        return next(iter(row.values())) if row else None

    def _exec(self, sql, params=()):
        with self._connect() as conn, conn.cursor() as cur:
            cur.execute(sql, params)
            return cur.rowcount
