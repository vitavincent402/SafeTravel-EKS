"""KMS 봉투 암호화 (앱·데이터 담당).

서류 하나마다
  1. KMS에 "데이터 키"를 하나 만들어 달라고 한다 (GenerateDataKey, AES-256).
     → 평문 키(메모리에서만 씀)와 KMS 키로 암호화된 키 두 개를 받는다.
  2. 평문 키로 서류를 AES-256-GCM으로 암호화한다 (내용이 바뀌면 복호화 실패로 알 수 있음).
  3. 암호화된 서류는 S3에, 암호화된 키는 DB(documents.encrypted_data_key)에 저장한다.
  4. 평문 키는 저장하지 않는다.
열람할 때는 KMS Decrypt로 키를 풀고 서류를 복호화한다.

암호화 문맥(EncryptionContext)에 서류 번호와 주인 번호를 넣는다.
  - 다른 서류의 키를 가져다 쓰면 KMS가 복호화를 거부한다.
  - CloudTrail의 KMS 기록에 어느 서류였는지 남는다.
api 역할에는 KMS 권한이 없어서, api가 뚫려도 서류를 풀 수 없다.
"""
import json
import os

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

FORMAT_V1 = b"KPR1"  # 저장 형식 표시 (나중에 방식이 바뀌어도 구분)
NONCE_SIZE = 12


class DecryptError(Exception):
    pass


def _aad(context):
    return json.dumps(context, sort_keys=True, separators=(",", ":")).encode()


def encrypt_document(kms, key_id, plaintext, context):
    """(S3에 저장할 바이트, DB에 저장할 암호화된 데이터 키)"""
    resp = kms.generate_data_key(KeyId=key_id, KeySpec="AES_256", EncryptionContext=context)
    data_key = resp["Plaintext"]
    nonce = os.urandom(NONCE_SIZE)
    ciphertext = AESGCM(data_key).encrypt(nonce, plaintext, _aad(context))
    del data_key
    return FORMAT_V1 + nonce + ciphertext, resp["CiphertextBlob"]


def decrypt_document(kms, key_id, blob, encrypted_data_key, context):
    if not encrypted_data_key:
        raise DecryptError("데이터 키가 없음 (삭제된 서류)")
    if not blob.startswith(FORMAT_V1):
        raise DecryptError("알 수 없는 저장 형식")
    resp = kms.decrypt(CiphertextBlob=encrypted_data_key, KeyId=key_id, EncryptionContext=context)
    data_key = resp["Plaintext"]
    nonce = blob[len(FORMAT_V1):len(FORMAT_V1) + NONCE_SIZE]
    try:
        return AESGCM(data_key).decrypt(nonce, blob[len(FORMAT_V1) + NONCE_SIZE:], _aad(context))
    except Exception as e:  # noqa: BLE001
        raise DecryptError("복호화 실패 (내용이 바뀌었거나 다른 키)") from e
    finally:
        del data_key
