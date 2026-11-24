"""DB 연결과 table 만들기 (앱·데이터 담당).

- DB 비밀번호는 환경 변수에 없다. DB_SECRET_ARN(위치)만 받고,
  파드가 IRSA 권한으로 Secrets Manager에서 직접 읽는다.
- RDS가 비밀번호를 주기적으로 바꾸므로, 로그인 실패 시 한 번 다시 읽는다.
- api 파드가 2개라 동시에 table을 만들 수 있어서, DB 잠금(advisory lock)으로 하나씩 실행한다.
"""
import json
import os
import threading

SCHEMA_LOCK_ID = 7_301_001  # table 만들기 전용 잠금 번호 (아무 숫자나 고정)
SCHEMA_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "schema.sql")


def make_connect(host, dbname, secret_arn, region):
    """호출하면 새 DB 연결을 돌려주는 함수를 만든다."""
    import boto3
    import psycopg

    sm = boto3.client("secretsmanager", region_name=region)
    cache = {}
    lock = threading.Lock()

    def load_secret(force=False):
        with lock:
            if force or "value" not in cache:
                raw = sm.get_secret_value(SecretId=secret_arn)["SecretString"]
                cache["value"] = json.loads(raw)
            return cache["value"]

    def open_conn(secret):
        return psycopg.connect(
            host=host, dbname=dbname,
            user=secret["username"], password=secret["password"],
            sslmode="require", connect_timeout=5,
        )

    def connect():
        try:
            return open_conn(load_secret())
        except psycopg.OperationalError:
            return open_conn(load_secret(force=True))  # 비밀번호가 바뀌었을 수 있음

    return connect


def apply_schema(connect, path=SCHEMA_PATH):
    """schema.sql 실행. IF NOT EXISTS라 여러 번 실행해도 안전."""
    with open(path, encoding="utf-8") as f:
        sql = f.read()
    with connect() as conn:
        # 이 트랜잭션이 끝날 때 잠금이 자동으로 풀림
        conn.execute("SELECT pg_advisory_xact_lock(%s)", (SCHEMA_LOCK_ID,))
        conn.execute(sql)
