import json
from uuid import uuid4

import httpx
import pytest

from app.api.deps import get_voting_repository
from app.core.config import Settings
from app.repositories.postgrest import PostgrestClient
from app.repositories.voting import SupabaseVotingRepository
from app.repositories.workspace import SupabaseRepository
from app.schemas.api import MyVoteOut, TurnoutOut, VoteReceiptOut
from app.security.auth import AuthenticatedUser

EID, ORG = uuid4(), uuid4()
RECEIPT = "ab" * 32


class FakeVoting:
    def __init__(self):
        self.calls: list[tuple] = []

    async def cast(self, user, election, selections):
        self.calls.append(("cast", [str(s) for s in selections]))
        return VoteReceiptOut(receipt=RECEIPT, changed=False)

    async def my_vote(self, user, election):
        return MyVoteOut(voted=True, can_change=True, selections=[uuid4()])

    async def turnout(self, user, election):
        return TurnoutOut(voted=3, eligible=10)

    async def verify_receipt(self, user, election, receipt):
        self.calls.append(("verify", receipt))
        return receipt == RECEIPT


@pytest.fixture
def voting(client):
    fake = FakeVoting()
    client.app.dependency_overrides[get_voting_repository] = lambda: fake
    return fake


@pytest.mark.parametrize("method,path", [
    ("post", f"/api/v1/elections/{EID}/vote"), ("get", f"/api/v1/elections/{EID}/vote"),
    ("get", f"/api/v1/elections/{EID}/turnout"), ("post", f"/api/v1/elections/{EID}/receipt/verify"),
])
def test_voting_routes_require_authentication(client, voting, method, path):
    assert getattr(client, method)(path).status_code == 401


def test_cast_vote_passes_selections_only(client, auth, voting):
    ids = [str(uuid4()), str(uuid4())]
    r = client.post(f"/api/v1/elections/{EID}/vote", json={"selections": ids}, headers=auth)
    assert r.status_code == 200 and r.json() == {"receipt": RECEIPT, "changed": False}
    assert voting.calls[-1] == ("cast", ids)
    assert client.post(f"/api/v1/elections/{EID}/vote", json={}, headers=auth).status_code == 200       # blank ballot: the database decides if it is allowed
    assert voting.calls[-1] == ("cast", [])


@pytest.mark.parametrize("body", [
    {"selections": ["nope"]}, {"selections": "x"}, {"selections": [str(uuid4())] * 201},
    {"selections": [], "user_id": str(uuid4())},          # identity never comes from the body
])
def test_cast_vote_validation(client, auth, voting, body):
    assert client.post(f"/api/v1/elections/{EID}/vote", json=body, headers=auth).status_code == 422


def test_status_turnout_and_receipt(client, auth, voting):
    assert client.get(f"/api/v1/elections/{EID}/vote", headers=auth).json()["can_change"] is True
    assert client.get(f"/api/v1/elections/{EID}/turnout", headers=auth).json() == {"voted": 3, "eligible": 10}
    ok = client.post(f"/api/v1/elections/{EID}/receipt/verify", json={"receipt": RECEIPT}, headers=auth)
    assert ok.json() == {"included": True}
    assert client.post(f"/api/v1/elections/{EID}/receipt/verify", json={"receipt": "cd" * 32}, headers=auth).json() == {"included": False}
    for bad in ("short", "z" * 64, RECEIPT + "0"):
        assert client.post(f"/api/v1/elections/{EID}/receipt/verify", json={"receipt": bad}, headers=auth).status_code == 422


def test_voting_rules_become_settings(client, auth, repo):
    body = {"title": "Council 2026", "voting_method": "plurality", "seats": 1, "allow_vote_change": False, "allow_blank_ballot": True}
    assert client.post(f"/api/v1/organisations/{ORG}/elections", json=body, headers=auth).status_code == 201
    assert repo.calls[-1] == ("create_election", {"allow_vote_change": False, "allow_blank_ballot": True})
    client.post(f"/api/v1/organisations/{ORG}/elections", json={**body, "allow_vote_change": None, "allow_blank_ballot": None}, headers=auth)
    assert repo.calls[-1] == ("create_election", {})                          # unset: database defaults apply
    assert client.post(f"/api/v1/organisations/{ORG}/elections", json={**body, "allow_vote_change": "maybe"}, headers=auth).status_code == 422


async def test_voting_repository_maps_rpc_calls():
    seen = []
    sel = str(uuid4())

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append((request.url.path.rsplit("/", 1)[-1], json.loads(request.content), request.headers["authorization"]))
        name = seen[-1][0]
        return httpx.Response(200, json={
            "cast_vote": {"receipt": RECEIPT, "changed": True},
            "my_vote": {"voted": True, "can_change": True, "selections": [sel]},
            "election_turnout": {"voted": 3, "eligible": None},
            "verify_receipt": True}[name])

    settings = Settings(app_env="test", supabase_url="https://x.supabase.co", supabase_anon_key="anon")
    user = AuthenticatedUser(id=uuid4(), email=None, token="user-jwt")
    repo = SupabaseVotingRepository(PostgrestClient(settings, transport=httpx.MockTransport(handler)))
    assert (await repo.cast(user, EID, [uuid4()])).changed is True
    assert seen[0][0] == "cast_vote" and seen[0][1]["p_election"] == str(EID) and seen[0][2] == "Bearer user-jwt"
    assert (await repo.my_vote(user, EID)).selections == [__import__("uuid").UUID(sel)]
    assert (await repo.turnout(user, EID)).eligible is None
    assert await repo.verify_receipt(user, EID, RECEIPT) is True


async def test_election_mapping_includes_voting_rules_with_defaults():
    def row(settings):
        return {"id": str(EID), "organisation_id": str(ORG), "title": "T", "description": None, "voting_method": "plurality", "seats": 1,
                "access": "restricted", "status": "open", "opens_at": None, "closes_at": None, "settings": settings, "published_at": None,
                "created_at": "2026-11-03T00:00:00+00:00", "updated_at": "2026-11-03T00:00:00+00:00"}

    answers = iter([row({}), row({"allow_vote_change": False, "allow_blank_ballot": True})])

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("election_organisation_name"):
            return httpx.Response(200, json="Org")
        if request.url.path.endswith("advance_elections"):
            return httpx.Response(200, json=0)
        return httpx.Response(200, json=[next(answers)])

    settings = Settings(app_env="test", supabase_url="https://x.supabase.co", supabase_anon_key="anon")
    repo = SupabaseRepository(PostgrestClient(settings, transport=httpx.MockTransport(handler)))
    user = AuthenticatedUser(id=uuid4(), email=None, token="t")
    default = await repo.get_election(user, EID)
    assert default.allow_vote_change is True and default.allow_blank_ballot is False
    chosen = await repo.get_election(user, EID)
    assert chosen.allow_vote_change is False and chosen.allow_blank_ballot is True
