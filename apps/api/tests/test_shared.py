"""api와 vault에 같은 내용으로 두는 공통 파일이 서로 다르지 않은지 확인."""
import filecmp
import os

import pytest

API = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VAULT = os.path.join(os.path.dirname(API), "vault")


@pytest.mark.parametrize("name", ["internal_auth.py", "rules.py", "web.py", "db.py", "store.py"])
def test_공통_파일이_같음(name):
    assert filecmp.cmp(os.path.join(API, name), os.path.join(VAULT, name), shallow=False), \
        f"{name}: apps/api와 apps/vault의 내용이 다름. 한쪽을 고쳤으면 다른 쪽에도 복사하세요"
