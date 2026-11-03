"""End-to-end test: FastAPI -> real PostgREST -> real PostgreSQL with the migrations applied.

Skipped unless these are set (see database/tests/README.md):
  NV_IT_POSTGREST_URL  e.g. http://localhost:3000          NV_IT_JWT_SECRET  secret PostgREST verifies tokens with
  NV_IT_PSQL_URL       superuser connection string used only to insert auth.users test rows
"""
import os
import subprocess
import time
from uuid import uuid4

import httpx
import jwt
import pytest
from fastapi.testclient import TestClient

from app.api.deps import get_repository
from app.core.config import Settings, get_settings
from app.main import create_app
from app.repositories.postgrest import PostgrestClient
from app.repositories.workspace import SupabaseRepository

URL, SECRET, PSQL = (os.environ.get(k) for k in ("NV_IT_POSTGREST_URL", "NV_IT_JWT_SECRET", "NV_IT_PSQL_URL"))
pytestmark = pytest.mark.skipif(not (URL and SECRET and PSQL), reason="integration environment not configured")


class StripRestPrefix(httpx.AsyncBaseTransport):
    """Supabase serves PostgREST under /rest/v1; a bare PostgREST serves at the root."""
    def __init__(self):
        self.inner = httpx.AsyncHTTPTransport()

    async def handle_async_request(self, request: httpx.Request) -> httpx.Response:
        request.url = request.url.copy_with(path=request.url.path.removeprefix("/rest/v1"))
        return await self.inner.handle_async_request(request)


def make_user(email: str, confirmed: bool = True) -> dict:
    uid = str(uuid4())
    sql = f"insert into auth.users (id, email, email_confirmed_at) values ('{uid}', '{email}', {'now()' if confirmed else 'null'})"
    subprocess.run(["psql", PSQL, "-qc", sql], check=True)
    token = jwt.encode({"sub": uid, "email": email, "role": "authenticated", "aud": "authenticated", "exp": int(time.time()) + 600}, SECRET, algorithm="HS256")
    return {"id": uid, "headers": {"Authorization": f"Bearer {token}"}}


@pytest.fixture(scope="module")
def client():
    app = create_app()
    settings = Settings(app_env="test", supabase_url=URL, supabase_anon_key="anon", supabase_jwt_secret=SECRET)
    app.dependency_overrides[get_settings] = lambda: settings
    app.dependency_overrides[get_repository] = lambda: SupabaseRepository(PostgrestClient(settings, transport=StripRestPrefix()))
    return TestClient(app)


def test_full_stack_workspace_members_elections(client):
    tag = uuid4().hex[:8]
    owner, voter, manager, outsider = (make_user(f"{n}-{tag}@it.test") for n in ("owner", "voter", "mgr", "out"))
    H = lambda u: u["headers"]  # noqa: E731

    org = client.post("/api/v1/organisations", json={"name": f"IT Org {tag}"}, headers=H(owner))
    assert org.status_code == 201, org.text
    oid = org.json()["id"]
    assert client.post("/api/v1/organisations", json={"name": f"IT Org {tag}"}, headers=H(outsider)).status_code == 409  # slug taken
    assert client.get("/api/v1/organisations", headers=H(owner)).json()[0]["role"] == "owner"
    assert client.get(f"/api/v1/organisations/{oid}/me", headers=H(outsider)).status_code == 404

    # invitations (+ unconfirmed/foreign users can't see them)
    for u, role in ((voter, "voter"), (manager, "election_manager")):
        r = client.post(f"/api/v1/organisations/{oid}/invitations", json={"email": u["headers"] and f"{'voter' if role == 'voter' else 'mgr'}-{tag}@it.test", "role": role}, headers=H(owner))
        assert r.status_code == 201, r.text
    assert client.post(f"/api/v1/organisations/{oid}/invitations", json={"email": f"voter-{tag}@it.test", "role": "voter"}, headers=H(owner)).status_code == 409
    assert len(client.get(f"/api/v1/organisations/{oid}/invitations", headers=H(owner)).json()) == 2
    assert client.get("/api/v1/invitations/mine", headers=H(outsider)).json() == []
    for u in (voter, manager):
        mine = client.get("/api/v1/invitations/mine", headers=H(u)).json()
        assert len(mine) == 1 and mine[0]["organisation_name"] == f"IT Org {tag}"
        assert client.post(f"/api/v1/invitations/{mine[0]['id']}/accept", headers=H(u)).status_code == 204
    assert client.get(f"/api/v1/organisations/{oid}/invitations", headers=H(owner)).json() == []

    # members (profile embedding) and role management
    members = client.get(f"/api/v1/organisations/{oid}/members", headers=H(owner)).json()
    assert {m["email"] for m in members} == {f"{n}-{tag}@it.test" for n in ("owner", "voter", "mgr")}
    assert client.patch(f"/api/v1/organisations/{oid}/members/{voter['id']}", json={"role": "owner"}, headers=H(manager)).status_code == 403
    assert client.patch(f"/api/v1/organisations/{oid}/members/{owner['id']}", json={"role": "voter"}, headers=H(owner)).status_code == 409  # last owner
    assert client.patch(f"/api/v1/organisations/{oid}/members/{voter['id']}", json={"role": "election_manager"}, headers=H(owner)).status_code == 204
    perms = client.get(f"/api/v1/organisations/{oid}/me", headers=H(voter)).json()
    assert perms["role"] == "election_manager" and "election.manage" in perms["permissions"]
    client.patch(f"/api/v1/organisations/{oid}/members/{voter['id']}", json={"role": "voter"}, headers=H(owner))

    # elections: validation, permissions, lifecycle
    body = {"title": "Council 2026", "voting_method": "d_hondt", "seats": 9, "threshold_percent": 5, "access": "restricted"}
    assert client.post(f"/api/v1/organisations/{oid}/elections", json=body, headers=H(voter)).status_code == 403
    r = client.post(f"/api/v1/organisations/{oid}/elections", json=body, headers=H(manager))
    assert r.status_code == 201, r.text
    e = r.json(); eid = e["id"]
    assert e["status"] == "draft" and e["threshold_percent"] == 5
    assert client.get(f"/api/v1/elections/{eid}", headers=H(voter)).status_code == 404        # drafts hidden from voters
    assert client.get(f"/api/v1/elections/{eid}", headers=H(outsider)).status_code == 404
    assert client.post(f"/api/v1/elections/{eid}/transition", json={"to": "scheduled"}, headers=H(manager)).status_code == 422  # no dates

    body.update(opens_at="2099-01-01T08:00:00+00:00", closes_at="2099-01-02T08:00:00+00:00", voting_method="sainte_lague")
    assert client.put(f"/api/v1/elections/{eid}", json=body, headers=H(manager)).json()["voting_method"] == "sainte_lague"
    # ballot builder + voter list gate scheduling
    sched = lambda: client.post(f"/api/v1/elections/{eid}/transition", json={"to": "scheduled"}, headers=H(manager))  # noqa: E731
    assert sched().status_code == 422 and "lists" in sched().json()["detail"]
    ready = {c["key"]: c["ok"] for c in client.get(f"/api/v1/elections/{eid}/readiness", headers=H(manager)).json()}
    assert ready == {"window": True, "future": True, "ballot": False, "voters": False}
    assert client.get(f"/api/v1/elections/{eid}/readiness", headers=H(voter)).status_code == 404
    greens = client.post(f"/api/v1/elections/{eid}/ballot/options", json={"label": "Greens", "members": ["Ann", "Bob"]}, headers=H(manager))
    reds = client.post(f"/api/v1/elections/{eid}/ballot/options", json={"label": "Reds"}, headers=H(manager))
    assert greens.status_code == 201 and reds.status_code == 201, greens.text
    assert client.post(f"/api/v1/elections/{eid}/ballot/options", json={"label": "greens"}, headers=H(manager)).status_code == 409
    assert client.put(f"/api/v1/elections/{eid}/ballot/order", json={"ids": [reds.json()["id"], greens.json()["id"]]}, headers=H(manager)).status_code == 204
    assert [o["label"] for o in client.get(f"/api/v1/elections/{eid}/ballot", headers=H(manager)).json()] == ["Reds", "Greens"]
    assert client.get(f"/api/v1/elections/{eid}/ballot", headers=H(voter)).json() == []          # drafts stay hidden from plain members
    res = client.post(f"/api/v1/elections/{eid}/voters", headers=H(manager), json={"voters": [
        {"email": f"out-{tag}@it.test", "name": "Olive Outsider"}, {"email": f"OUT-{tag}@it.test"}, {"email": "broken"}]})
    assert res.status_code == 200 and (res.json()["added"], res.json()["duplicates"], res.json()["invalid_count"]) == (1, 1, 1), res.text
    page = client.get(f"/api/v1/elections/{eid}/voters?search=olive", headers=H(manager)).json()
    assert page["total"] == 1 and page["all_total"] == 1 and page["items"][0]["name"] == "Olive Outsider"
    assert client.get(f"/api/v1/elections/{eid}/voters", headers=H(voter)).status_code == 404
    assert all(c["ok"] for c in client.get(f"/api/v1/elections/{eid}/readiness", headers=H(manager)).json())
    r = sched()
    assert r.status_code == 200 and r.json()["status"] == "scheduled"

    # eligible voters need not be workspace members
    assert client.get(f"/api/v1/organisations/{oid}/me", headers=H(outsider)).status_code == 404
    got = client.get(f"/api/v1/elections/{eid}", headers=H(outsider))
    assert got.status_code == 200 and got.json()["organisation_name"] == f"IT Org {tag}", got.text
    assert client.get(f"/api/v1/elections/{eid}/eligibility", headers=H(outsider)).json() == {"eligible": True}
    assert client.get(f"/api/v1/elections/{eid}/eligibility", headers=H(voter)).json() == {"eligible": False}   # member, but not on the roll
    assert [o["label"] for o in client.get(f"/api/v1/elections/{eid}/ballot", headers=H(outsider)).json()] == ["Reds", "Greens"]
    assert [e["title"] for e in client.get("/api/v1/elections/mine", headers=H(outsider)).json()] == ["Council 2026"]
    assert client.get("/api/v1/elections/mine", headers=H(voter)).json() == []
    assert client.get(f"/api/v1/elections/{eid}/voters", headers=H(outsider)).status_code == 404
    assert client.post(f"/api/v1/elections/{eid}/ballot/options", json={"label": "Late"}, headers=H(manager)).status_code == 409   # ballot locked
    assert client.post(f"/api/v1/elections/{eid}/transition", json={"to": "open"}, headers=H(outsider)).status_code == 404
    assert client.get(f"/api/v1/elections/{eid}", headers=H(voter)).json()["status"] == "scheduled"
    assert client.put(f"/api/v1/elections/{eid}", json=body, headers=H(manager)).status_code == 409
    assert client.post(f"/api/v1/elections/{eid}/transition", json={"to": "open"}, headers=H(manager)).json()["status"] == "open"
    assert client.post(f"/api/v1/elections/{eid}/transition", json={"to": "closed"}, headers=H(manager)).json()["status"] == "closed"
    assert client.post(f"/api/v1/elections/{eid}/transition", json={"to": "published"}, headers=H(manager)).status_code == 403
    assert client.post(f"/api/v1/elections/{eid}/transition", json={"to": "published"}, headers=H(owner)).json()["status"] == "published"
    assert len(client.get(f"/api/v1/organisations/{oid}/elections", headers=H(voter)).json()) == 1

    # removal
    assert client.delete(f"/api/v1/organisations/{oid}/members/{voter['id']}", headers=H(owner)).status_code == 204
    assert client.get(f"/api/v1/organisations/{oid}/me", headers=H(voter)).status_code == 404

    # single-winner ranked method (instant-runoff) end to end
    irv = {"title": "Chair 2026", "voting_method": "irv", "seats": 1}
    assert client.post(f"/api/v1/organisations/{oid}/elections", json={**irv, "seats": 2}, headers=H(manager)).status_code == 422
    r = client.post(f"/api/v1/organisations/{oid}/elections", json=irv, headers=H(manager))
    assert r.status_code == 201 and r.json()["voting_method"] == "irv" and r.json()["threshold_percent"] is None, r.text
    irv_id = r.json()["id"]
    assert client.post(f"/api/v1/elections/{irv_id}/ballot/options", json={"label": "Ana", "members": ["x"]}, headers=H(manager)).status_code == 422
    assert client.post(f"/api/v1/elections/{irv_id}/ballot/options", json={"label": "Ana"}, headers=H(manager)).status_code == 201

