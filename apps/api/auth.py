"""Cognito ID 토큰 확인 (앱·데이터 담당).

화면은 로그인 뒤 받은 ID 토큰을 `Authorization: Bearer <ID 토큰>` 으로 보낸다.
api는 Cognito에 묻지 않고 토큰을 직접 확인한다.

확인하는 것 5가지
  1. 서명: Cognito 공개 키(JWKS)로 서명이 맞는지 (위조 방지)
  2. 만료: exp 시각이 지나지 않았는지
  3. 발급자(iss): 우리 사용자 풀이 발급했는지
  4. 대상(aud): 우리 앱 클라이언트용 토큰인지
  5. 종류(token_use): ID 토큰인지 (access 토큰은 받지 않음)
"""
import json
import threading
import time
import urllib.request

import jwt


class TokenError(Exception):
    """토큰이 유효하지 않음. 이유는 로그에만 남기고 화면에는 401만 준다."""


class KeysUnavailable(Exception):
    """Cognito 공개 키를 가져오지 못함 (네트워크 문제). 화면에는 503을 준다."""


class CognitoVerifier:
    def __init__(self, region, user_pool_id, app_client_id,
                 fetch_jwks=None, leeway=30, min_refresh_interval=60):
        if not (region and user_pool_id and app_client_id):
            raise ValueError("region, user_pool_id, app_client_id가 모두 필요합니다")
        self.issuer = f"https://cognito-idp.{region}.amazonaws.com/{user_pool_id}"
        self.jwks_url = f"{self.issuer}/.well-known/jwks.json"
        self.client_id = app_client_id
        self.leeway = leeway                              # 서버 간 시계 차이 허용(초)
        self.min_refresh_interval = min_refresh_interval  # 공개 키를 너무 자주 다시 받지 않게
        self._fetch = fetch_jwks or self._fetch_from_cognito
        self._keys = {}
        self._last_refresh = 0.0
        self._lock = threading.Lock()

    def _fetch_from_cognito(self):
        with urllib.request.urlopen(self.jwks_url, timeout=5) as resp:
            return json.load(resp)

    def _refresh(self, force):
        with self._lock:
            now = time.monotonic()
            if self._keys and not force:
                return
            if self._keys and now - self._last_refresh < self.min_refresh_interval:
                return
            try:
                jwks = self._fetch()
            except Exception as e:  # noqa: BLE001
                if self._keys:
                    return  # 이전 키로 계속 동작
                raise KeysUnavailable(str(e)) from e
            keys = {}
            for k in jwks.get("keys", []):
                if k.get("kty") == "RSA" and k.get("kid"):
                    keys[k["kid"]] = jwt.PyJWK(k, algorithm="RS256").key
            self._keys = keys
            self._last_refresh = now

    def _key_for(self, kid):
        self._refresh(force=False)
        if kid not in self._keys:
            # Cognito가 키를 바꿨을 수 있으니 한 번만 다시 받아 본다
            self._refresh(force=True)
        if kid not in self._keys:
            raise TokenError("모르는 서명 키(kid)")
        return self._keys[kid]

    def verify(self, token):
        """맞으면 토큰 내용(claims)을 돌려주고, 틀리면 TokenError."""
        try:
            header = jwt.get_unverified_header(token)
        except jwt.PyJWTError as e:
            raise TokenError("토큰 형식 오류") from e
        if header.get("alg") != "RS256":
            raise TokenError("허용하지 않는 서명 방식")
        key = self._key_for(header.get("kid"))
        try:
            claims = jwt.decode(
                token, key,
                algorithms=["RS256"],
                audience=self.client_id,
                issuer=self.issuer,
                leeway=self.leeway,
                options={"require": ["exp", "iat", "iss", "aud", "sub", "token_use"]},
            )
        except jwt.ExpiredSignatureError as e:
            raise TokenError("만료된 토큰") from e
        except jwt.PyJWTError as e:
            raise TokenError(f"확인 실패: {type(e).__name__}") from e
        if claims.get("token_use") != "id":
            raise TokenError("ID 토큰이 아님")
        return claims
