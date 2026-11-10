"""PostgREST client that forwards the *user's* JWT so Row Level Security always applies.

Application errors raised by our SQL functions carry custom SQLSTATEs (NV403/404/409/422); their messages are
written by us and safe to show. Every other database error is hidden behind a generic message.
"""
from typing import Any

import httpx
from fastapi import HTTPException, status

from app.core.config import Settings
from app.security.auth import AuthenticatedUser

_APP_ERRORS = {"NV403": 403, "NV404": 404, "NV409": 409, "NV422": 422}


def map_error(resp: httpx.Response) -> HTTPException:
    try:
        body = resp.json()
    except ValueError:
        body = {}
    code = body.get("code") if isinstance(body, dict) else None
    if code in _APP_ERRORS:
        return HTTPException(_APP_ERRORS[code], str(body.get("message", "Request rejected")))
    if code == "23505":
        return HTTPException(status.HTTP_409_CONFLICT, "That already exists")
    if code in ("28000", "PGRST301", "PGRST303") or resp.status_code == 401:
        return HTTPException(status.HTTP_401_UNAUTHORIZED, "Session expired. Sign in again")
    if code == "42501" or resp.status_code == 403:
        return HTTPException(status.HTTP_403_FORBIDDEN, "You don't have permission to do that")
    return HTTPException(status.HTTP_502_BAD_GATEWAY, "The database request failed")


class PostgrestClient:
    def __init__(self, settings: Settings, transport: httpx.AsyncBaseTransport | None = None) -> None:
        if not settings.supabase_configured:
            raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "Database is not configured")
        self._base = settings.supabase_url.rstrip("/") + "/rest/v1"
        self._anon = settings.supabase_anon_key
        self._transport = transport

    async def call(self, method: str, path: str, user: AuthenticatedUser, *,
                   params: dict[str, str] | None = None, json: Any = None) -> Any:
        headers = {"apikey": self._anon, "Authorization": f"Bearer {user.token}", "Content-Type": "application/json"}
        try:
            async with httpx.AsyncClient(timeout=10, transport=self._transport) as client:
                resp = await client.request(method, self._base + path, headers=headers, params=params, json=json)
        except httpx.HTTPError:
            raise HTTPException(status.HTTP_502_BAD_GATEWAY, "Database is unreachable") from None
        if resp.status_code >= 400:
            raise map_error(resp)
        return None if resp.status_code == 204 or not resp.content else resp.json()

    def rpc(self, name: str, user: AuthenticatedUser, payload: dict[str, Any] | None = None):
        return self.call("POST", f"/rpc/{name}", user, json=payload or {})
