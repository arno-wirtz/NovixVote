import json
from uuid import uuid4

import httpx
import pytest
from fastapi import HTTPException

from app.core.config import Settings
from app.repositories.postgrest import PostgrestClient, map_error
from app.repositories.workspace import SupabaseRepository
from app.security.auth import AuthenticatedUser

ORG = uuid4()
ELECTION = {"title": "Council 2026", "voting_method": "d_hondt", "seats": 9, "threshold_percent": 5}


@pytest.mark.parametrize("method,path", [
    ("get", f"/api/v1/organisations/{ORG}/members"), ("get", f"/api/v1/organisations/{ORG}/me"),
    ("post", f"/api/v1/organisations/{ORG}/invitations"), ("get", "/api/v1/invitations/mine"),
    ("get", f"/api/v1/organisations/{ORG}/elections"), ("post", f"/api/v1/elections/{uuid4()}/transition"),
    ("delete", f"/api/v1/elections/{uuid4()}"),
])
def test_phase2_routes_require_authentication(client, method, path):
    assert getattr(client, method)(path).status_code == 401


def test_invitation_flow(client, auth, repo):
    r = client.post(f"/api/v1/organisations/{ORG}/invitations", json={"email": "  New@Example.COM ", "role": "voter"}, headers=auth)
    assert r.status_code == 201 and r.json()["email"] == "new@example.com"
    assert repo.calls[-1] == ("create_invitation", "new@example.com", "voter")
    assert client.get("/api/v1/invitations/mine", headers=auth).json()[0]["organisation_name"] == "Demo"
    inv = uuid4()
    assert client.post(f"/api/v1/invitations/{inv}/accept", headers=auth).status_code == 204
    assert client.post(f"/api/v1/invitations/{inv}/decline", headers=auth).status_code == 204
    assert client.delete(f"/api/v1/invitations/{inv}", headers=auth).status_code == 204
    assert [c[:1] + c[2:] for c in repo.calls[-3:]] == [("respond", True), ("respond", False), ("revoke_invitation",)]


@pytest.mark.parametrize("body", [{"email": "nope", "role": "voter"}, {"email": "a@b.co", "role": "owner"},
                                  {"email": "a@b.co", "role": "root"}, {"role": "voter"}])
def test_invitation_validation(client, auth, body):
    assert client.post(f"/api/v1/organisations/{ORG}/invitations", json=body, headers=auth).status_code == 422


def test_role_change_and_removal(client, auth, repo):
    member = uuid4()
    assert client.patch(f"/api/v1/organisations/{ORG}/members/{member}", json={"role": "admin"}, headers=auth).status_code == 204
    assert client.patch(f"/api/v1/organisations/{ORG}/members/{member}", json={"role": "superuser"}, headers=auth).status_code == 422
    assert client.delete(f"/api/v1/organisations/{ORG}/members/{member}", headers=auth).status_code == 204
    assert repo.calls == [("change_role", str(member), "admin"), ("remove_member", str(member))]


def test_non_members_get_404_not_data(client, auth, repo):
    repo.role = "none"
    for path in ("members", "elections", "me"):
        assert client.get(f"/api/v1/organisations/{ORG}/{path}", headers=auth).status_code == 404


def test_create_election_builds_method_settings(client, auth, repo):
    r = client.post(f"/api/v1/organisations/{ORG}/elections", json=ELECTION, headers=auth)
    assert r.status_code == 201 and repo.calls[-1] == ("create_election", {"threshold_percent": 5})
    client.post(f"/api/v1/organisations/{ORG}/elections", json={**ELECTION, "voting_method": "sainte_lague", "threshold_percent": None}, headers=auth)
    assert repo.calls[-1][1] == {"threshold_percent": 0}
    client.post(f"/api/v1/organisations/{ORG}/elections", json={**ELECTION, "voting_method": "plurality", "threshold_percent": None, "seats": 1}, headers=auth)
    assert repo.calls[-1][1] == {}


@pytest.mark.parametrize("patch", [
    {"voting_method": "borda"}, {"voting_method": "plurality", "threshold_percent": 5}, {"seats": 0}, {"seats": 101},
    {"title": "ab"}, {"threshold_percent": 120}, {"access": "secret"},
    {"opens_at": "2027-01-02T00:00:00Z", "closes_at": "2027-01-01T00:00:00Z"},
    {"opens_at": "2027-01-01T00:00:00", "closes_at": "2027-01-02T00:00:00"},   # naive datetimes are ambiguous: rejected
])
def test_election_validation(client, auth, patch):
    assert client.post(f"/api/v1/organisations/{ORG}/elections", json={**ELECTION, **patch}, headers=auth).status_code == 422


def test_transition_and_delete(client, auth, repo):
    eid = uuid4()
    r = client.post(f"/api/v1/elections/{eid}/transition", json={"to": "scheduled"}, headers=auth)
    assert r.status_code == 200 and r.json()["status"] == "scheduled"
    assert client.post(f"/api/v1/elections/{eid}/transition", json={"to": "archived"}, headers=auth).status_code == 422
    assert client.delete(f"/api/v1/elections/{eid}", headers=auth).status_code == 204
    assert client.get(f"/api/v1/elections/{eid}", headers=auth).status_code == 404


def test_voting_methods_expose_proportional_systems(client, auth):
    data = {m["key"]: m for m in client.get("/api/v1/voting-methods", headers=auth).json()}
    assert data["d_hondt"]["supports_threshold"] and data["sainte_lague"]["ballot_type"] == "party_list"
    assert not data["plurality"]["supports_threshold"]


# ---- Postgrest client: error mapping and token forwarding ----
def resp(status, body):
    return httpx.Response(status, json=body)


@pytest.mark.parametrize("status,body,expected", [
    (400, {"code": "NV403", "message": "You can't do that"}, 403), (400, {"code": "NV404", "message": "x"}, 404),
    (400, {"code": "NV409", "message": "x"}, 409), (400, {"code": "NV422", "message": "x"}, 422),
    (409, {"code": "23505", "message": "dup"}, 409), (401, {"code": "PGRST301", "message": "JWT expired"}, 401),
    (403, {"code": "42501", "message": "permission denied for table x"}, 403), (500, {"code": "XX000", "message": "internal: secret"}, 502),
])
def test_error_mapping(status, body, expected):
    assert map_error(resp(status, body)).status_code == expected


def test_unexpected_database_errors_never_leak_details():
    err = map_error(resp(500, {"code": "XX000", "message": "relation secret_table does not exist"}))
    assert "secret_table" not in err.detail
    assert map_error(resp(400, {"code": "NV409", "message": "A workspace needs at least one owner"})).detail == "A workspace needs at least one owner"


async def test_client_forwards_user_token_and_parses_rpc():
    seen = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["auth"], seen["apikey"], seen["url"], seen["body"] = request.headers["authorization"], request.headers["apikey"], str(request.url), json.loads(request.content)
        return httpx.Response(200, json=[{"role": "admin", "permissions": ["org.read"]}])

    settings = Settings(app_env="test", supabase_url="https://x.supabase.co", supabase_anon_key="anon-key")
    user = AuthenticatedUser(id=uuid4(), email="a@b.co", token="user-jwt")
    repo = SupabaseRepository(PostgrestClient(settings, transport=httpx.MockTransport(handler)))
    m = await repo.membership(user, ORG)
    assert m.role == "admin" and seen["auth"] == "Bearer user-jwt" and seen["apikey"] == "anon-key"
    assert seen["url"].endswith("/rest/v1/rpc/my_membership") and seen["body"] == {"p_org": str(ORG)}


async def test_client_maps_database_failures_and_empty_membership():
    settings = Settings(app_env="test", supabase_url="https://x.supabase.co", supabase_anon_key="anon")
    user = AuthenticatedUser(id=uuid4(), email=None, token="t")
    bad = PostgrestClient(settings, transport=httpx.MockTransport(lambda r: httpx.Response(400, json={"code": "NV409", "message": "Nope"})))
    with pytest.raises(HTTPException) as e:
        await SupabaseRepository(bad).remove_member(user, ORG, uuid4())
    assert e.value.status_code == 409 and e.value.detail == "Nope"
    empty = PostgrestClient(settings, transport=httpx.MockTransport(lambda r: httpx.Response(200, json=[])))
    assert await SupabaseRepository(empty).membership(user, ORG) is None


async def test_reads_survive_failed_housekeeping_call():
    calls = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(request.url.path)
        return httpx.Response(500, json={"code": "XX000", "message": "boom"}) if request.url.path.endswith("advance_elections") else httpx.Response(200, json=[])

    settings = Settings(app_env="test", supabase_url="https://x.supabase.co", supabase_anon_key="anon")
    repo = SupabaseRepository(PostgrestClient(settings, transport=httpx.MockTransport(handler)))
    assert await repo.list_elections(AuthenticatedUser(id=uuid4(), email=None, token="t"), ORG) == []
    assert calls[0].endswith("advance_elections") and calls[1].endswith("/elections")


def test_postgrest_requires_configuration():
    with pytest.raises(HTTPException) as e:
        PostgrestClient(Settings(app_env="test"))
    assert e.value.status_code == 503


def test_single_winner_methods_limit_seats(client, auth, repo):
    base = {"title": "Chair 2026", "voting_method": "irv", "seats": 1}
    assert client.post(f"/api/v1/organisations/{ORG}/elections", json=base, headers=auth).status_code == 201
    assert repo.calls[-1] == ("create_election", {})
    r = client.post(f"/api/v1/organisations/{ORG}/elections", json={**base, "seats": 2}, headers=auth)
    assert r.status_code == 422 and "exactly 1 seat" in r.json()["detail"]
    assert client.post(f"/api/v1/organisations/{ORG}/elections", json={**base, "threshold_percent": 5}, headers=auth).status_code == 422
    data = {m["key"]: m for m in client.get("/api/v1/voting-methods", headers=auth).json()}
    assert data["irv"]["max_seats"] == 1 and data["irv"]["ballot_type"] == "ranked" and data["plurality"]["max_seats"] is None
