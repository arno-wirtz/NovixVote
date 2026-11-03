from uuid import uuid4

import httpx
import pytest

from app.core.config import Settings
from app.repositories.postgrest import PostgrestClient
from app.repositories.workspace import SupabaseRepository
from app.security.auth import AuthenticatedUser

EID, OID, VID = uuid4(), uuid4(), uuid4()


@pytest.mark.parametrize("method,path", [
    ("get", f"/api/v1/elections/{EID}/ballot"), ("post", f"/api/v1/elections/{EID}/ballot/options"), ("put", f"/api/v1/ballot/options/{OID}"),
    ("delete", f"/api/v1/ballot/options/{OID}"), ("put", f"/api/v1/elections/{EID}/ballot/order"), ("get", f"/api/v1/elections/{EID}/voters"),
    ("post", f"/api/v1/elections/{EID}/voters"), ("delete", f"/api/v1/voters/{VID}"), ("get", f"/api/v1/elections/{EID}/readiness"),
    ("get", f"/api/v1/elections/{EID}/eligibility"), ("get", "/api/v1/elections/mine"),
])
def test_phase3_routes_require_authentication(client, method, path):
    assert getattr(client, method)(path).status_code == 401


def test_elections_mine_is_not_shadowed_by_the_id_route(client, auth):
    r = client.get("/api/v1/elections/mine", headers=auth)
    assert r.status_code == 200 and r.json()[0]["title"] == "Council"


def test_ballot_option_crud(client, auth, repo):
    r = client.post(f"/api/v1/elections/{EID}/ballot/options", json={"label": "  Greens ", "members": ["Ann", "Bob"]}, headers=auth)
    assert r.status_code == 201 and r.json()["label"] == "Greens"
    assert repo.calls[-1] == ("add_option", "Greens", ["Ann", "Bob"])
    assert client.put(f"/api/v1/ballot/options/{OID}", json={"label": "Reds"}, headers=auth).status_code == 200
    assert client.delete(f"/api/v1/ballot/options/{OID}", headers=auth).status_code == 204
    ids = [str(uuid4()), str(uuid4())]
    assert client.put(f"/api/v1/elections/{EID}/ballot/order", json={"ids": ids}, headers=auth).status_code == 204
    assert repo.calls[-1] == ("reorder", ids)


@pytest.mark.parametrize("body", [
    {"label": ""}, {"label": "   "}, {"label": "x" * 121}, {"label": "ok", "description": "d" * 501},
    {"label": "ok", "members": [""]}, {"label": "ok", "members": ["m"] * 101}, {"label": "ok", "members": "Ann"}, {},
])
def test_ballot_option_validation(client, auth, body):
    assert client.post(f"/api/v1/elections/{EID}/ballot/options", json=body, headers=auth).status_code == 422


def test_reorder_rejects_non_uuids(client, auth):
    assert client.put(f"/api/v1/elections/{EID}/ballot/order", json={"ids": ["nope"]}, headers=auth).status_code == 422


def test_voters_upload_is_lenient_per_row_but_bounded(client, auth, repo):
    rows = [{"email": "a@b.io", "name": "A"}, {"email": "not-an-email"}]
    r = client.post(f"/api/v1/elections/{EID}/voters", json={"voters": rows}, headers=auth)
    assert r.status_code == 200 and repo.calls[-1] == ("add_voters", ["a@b.io", "not-an-email"])   # bad rows reach the DB, which reports them per row
    assert client.post(f"/api/v1/elections/{EID}/voters", json={"voters": []}, headers=auth).status_code == 422
    big = {"voters": [{"email": f"u{i}@b.io"} for i in range(1001)]}
    assert client.post(f"/api/v1/elections/{EID}/voters", json=big, headers=auth).status_code == 422
    assert client.post(f"/api/v1/elections/{EID}/voters", json={"voters": [{"email": "x" * 321}]}, headers=auth).status_code == 422


def test_voter_page_params(client, auth, repo):
    assert client.get(f"/api/v1/elections/{EID}/voters?limit=25&offset=50&search=ann", headers=auth).status_code == 200
    assert repo.calls[-1] == ("voter_page", 25, 50, "ann")
    for q in ("limit=0", "limit=201", "offset=-1", "search=" + "x" * 101):
        assert client.get(f"/api/v1/elections/{EID}/voters?{q}", headers=auth).status_code == 422
    assert client.delete(f"/api/v1/voters/{VID}", headers=auth).status_code == 204


def test_readiness_and_eligibility(client, auth):
    r = client.get(f"/api/v1/elections/{EID}/readiness", headers=auth).json()
    assert r[0]["ok"] is False and "lists" in r[0]["problem"]
    assert client.get(f"/api/v1/elections/{EID}/eligibility", headers=auth).json() == {"eligible": True}


async def test_repository_maps_ballot_voter_and_eligibility_calls():
    seen = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append((request.method, request.url.path, request.content.decode() if request.content else ""))
        path = request.url.path
        if path.endswith("election_voter_page"):
            return httpx.Response(200, json={"total": 1, "all_total": 2, "items": [{"id": str(uuid4()), "email": "a@b.io", "name": None, "created_at": "2026-11-03T00:00:00+00:00"}]})
        if path.endswith("is_eligible_voter"):
            return httpx.Response(200, json=True)
        if path.endswith("election_readiness"):
            return httpx.Response(200, json=[{"key": "ballot", "ok": True, "label": "l", "problem": "p"}])
        if path.endswith("election_organisation_name"):
            return httpx.Response(200, json="Epsilon Guild")
        if path.endswith("/elections"):
            return httpx.Response(200, json=[{"id": str(EID), "organisation_id": str(uuid4()), "title": "T", "description": None, "voting_method": "d_hondt",
                                              "seats": 3, "access": "restricted", "status": "scheduled", "opens_at": None, "closes_at": None, "settings": {"threshold_percent": 5},
                                              "published_at": None, "created_at": "2026-11-03T00:00:00+00:00", "updated_at": "2026-11-03T00:00:00+00:00"}])
        return httpx.Response(200, json=[])

    settings = Settings(app_env="test", supabase_url="https://x.supabase.co", supabase_anon_key="anon")
    user = AuthenticatedUser(id=uuid4(), email=None, token="t")
    repo = SupabaseRepository(PostgrestClient(settings, transport=httpx.MockTransport(handler)))
    page = await repo.voter_page(user, EID, 10, 0, "a")
    assert page.total == 1 and page.items[0].email == "a@b.io"
    assert await repo.eligible(user, EID) is True
    assert (await repo.readiness(user, EID))[0].ok
    e = await repo.get_election(user, EID)
    assert e.organisation_name == "Epsilon Guild" and e.threshold_percent == 5
    assert await repo.ballot(user, EID) == []

