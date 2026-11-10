"""Supabase JWT verification.

Supports HS256 (legacy shared secret) and asymmetric signing keys (ES256/RS256 via JWKS).
The algorithm is chosen from an allow-list, never trusted blindly from the token ("none" is rejected).
"""
from dataclasses import dataclass, field
from functools import lru_cache
from uuid import UUID

import jwt
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from jwt import PyJWKClient

from app.core.config import Settings, get_settings

_bearer = HTTPBearer(auto_error=False)
_ALLOWED_ALGS = {"HS256", "ES256", "RS256"}


@dataclass(frozen=True)
class AuthenticatedUser:
    id: UUID
    email: str | None
    # Forwarded to Supabase so Row Level Security applies as this user. Never log it.
    token: str = field(repr=False)


@lru_cache
def _jwks_client(url: str) -> PyJWKClient:
    return PyJWKClient(url, cache_keys=True)


def _unauthorized(detail: str = "Invalid or missing credentials") -> HTTPException:
    return HTTPException(status.HTTP_401_UNAUTHORIZED, detail, headers={"WWW-Authenticate": "Bearer"})


def decode_token(token: str, settings: Settings) -> dict:
    try:
        alg = jwt.get_unverified_header(token).get("alg")
        if alg not in _ALLOWED_ALGS:
            raise _unauthorized()
        if alg == "HS256":
            if not settings.supabase_jwt_secret:
                raise _unauthorized()
            key = settings.supabase_jwt_secret
        else:
            if not settings.supabase_url:
                raise _unauthorized()
            jwks = f"{settings.supabase_url.rstrip('/')}/auth/v1/.well-known/jwks.json"
            key = _jwks_client(jwks).get_signing_key_from_jwt(token).key
        return jwt.decode(
            token, key, algorithms=[alg], audience="authenticated",
            options={"require": ["exp", "sub"]},
        )
    except HTTPException:
        raise
    except Exception:  # noqa: BLE001 - any failure is an authentication failure
        raise _unauthorized() from None


def get_current_user(
    creds: HTTPAuthorizationCredentials | None = Depends(_bearer),
    settings: Settings = Depends(get_settings),
) -> AuthenticatedUser:
    if creds is None or creds.scheme.lower() != "bearer":
        raise _unauthorized()
    claims = decode_token(creds.credentials, settings)
    try:
        user_id = UUID(claims["sub"])
    except (ValueError, KeyError):
        raise _unauthorized() from None
    return AuthenticatedUser(id=user_id, email=claims.get("email"), token=creds.credentials)
