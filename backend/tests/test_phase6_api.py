import json
from uuid import uuid4

import httpx
import pytest

from app.api.deps import get_results_repository
from app.core.config import Settings
from app.domain.tabulation import ballot_set_hash
from app.repositories.postgrest import PostgrestClient
from app.repositories.results import SupabaseResultsRepository
from app.schemas.api import AuditEventOut, AuditVerifyOut, PublishedResultOut, TallyRunOut
from app.security.auth import AuthenticatedUser

EID, ORG, NOW = uuid4(), uuid4(), "2026-11-05T10:00:00+00:00"
OPTS = [{"id": str(uuid4()), "label": "Ana"}, {"id": str(uuid4()), "label": "Ben"}]


class FakeResults:
    def __init__(self, ballots=None, hash_override=None):
        self.ballots = ballots if ballots is not None else [[OPTS[0]["id"]], [OPTS[1]["id"]], [OPTS[0]["id"]]]
        self.hash_override = hash_override
        self.calls: list[tuple] = []
        self.runs: list[TallyRunOut] = []

    async def tally_input(self, user, election):
        return {"method": "plurality", "seats": 1, "settings": {}, "options": OPTS, "ballots": self.ballots, "ballot_count": len(self.ballots),
                "hash": self.hash_override or ballot_set_hash(self.ballots)}

    async def record_run(self, user, election, input_hash, result, tie_break):
        self.calls.append(("record", input_hash, result["complete"], tie_break))
        run = TallyRunOut(id=uuid4(), run_number=len(self.runs) + 1, created_at=NOW, input_hash=input_hash, ballot_count=len(self.ballots),
                          tie_break=tie_break, result=result)
        self.runs.append(run)
        return run.id

    async def list_runs(self, user, election):
        return list(reversed(self.runs))

    async def approve(self, user, run):
        self.calls.append(("approve", str(run)))

    async def published(self, user, election):
        return PublishedResultOut(ballot_count=3, run_number=1, result={"complete": True}) if self.calls else None

    async def audit_page(self, user, org, limit, before):
        self.calls.append(("audit", limit, before))
        return [AuditEventOut(id=7, event_type="vote.accepted", created_at=NOW, hash="h" * 64)]

    async def verify_audit(self, user, org):
        return AuditVerifyOut(ok=True, checked=7)


@pytest.fixture
def results(client):
    fake = FakeResults()
    client.app.dependency_overrides[get_results_repository] = lambda: fake
    return fake


@pytest.mark.parametrize("method,path", [
    ("post", f"/api/v1/elections/{EID}/tally"), ("get", f"/api/v1/elections/{EID}/tally-runs"), ("post", f"/api/v1/tally-runs/{uuid4()}/approve"),
    ("get", f"/api/v1/elections/{EID}/results"), ("get", f"/api/v1/organisations/{ORG}/audit"), ("get", f"/api/v1/organisations/{ORG}/audit/verify"),
])
def test_phase6_routes_require_authentication(client, results, method, path):
    assert getattr(client, method)(path).status_code == 401


def test_tally_counts_and_records_a_run(client, auth, results):
    r = client.post(f"/api/v1/elections/{EID}/tally", json={}, headers=auth)
    assert r.status_code == 201
    body = r.json()
    assert body["run_number"] == 1 and body["result"]["winners"] == ["Ana"] and body["result"]["complete"] is True
    assert results.calls[-1] == ("record", ballot_set_hash(results.ballots), True, None)


def test_tie_needs_a_recorded_tie_break_then_a_new_run_completes_it(client, auth):
    fake = FakeResults(ballots=[[OPTS[0]["id"]], [OPTS[1]["id"]]])
    client.app.dependency_overrides[get_results_repository] = lambda: fake
    first = client.post(f"/api/v1/elections/{EID}/tally", json={}, headers=auth).json()
    assert first["result"]["complete"] is False and set(first["result"]["tied_for_last_seat"]) == {"Ana", "Ben"}
    tb = {"method": "lots", "note": "Returning officer drew lots", "order": ["Ben", "Ana"]}
    second = client.post(f"/api/v1/elections/{EID}/tally", json={"tie_break": tb}, headers=auth).json()
    assert second["run_number"] == 2 and second["result"]["complete"] and second["result"]["winners"] == ["Ben"] and second["tie_break"]["note"].startswith("Returning")
    assert [r["run_number"] for r in client.get(f"/api/v1/elections/{EID}/tally-runs", headers=auth).json()] == [2, 1]   # the first run is kept


@pytest.mark.parametrize("tie_break", [
    {"method": "lots", "note": "x", "order": ["Ana"]},                               # note too short
    {"method": "coin", "note": "flipped", "order": ["Ana"]},                         # unknown method
    {"method": "lots", "note": "drawn", "order": []},
    {"method": "lots", "note": "drawn", "order": ["Zed"]},                           # not on the ballot (engine layer)
    {"method": "lots", "note": "drawn", "order": ["Ana", "Ana"]},
])
def test_tie_break_validation(client, auth, results, tie_break):
    assert client.post(f"/api/v1/elections/{EID}/tally", json={"tie_break": tie_break}, headers=auth).status_code == 422
    assert not results.calls


def test_unverifiable_ballot_set_is_refused(client, auth):
    fake = FakeResults(hash_override="0" * 64)
    client.app.dependency_overrides[get_results_repository] = lambda: fake
    assert client.post(f"/api/v1/elections/{EID}/tally", json={}, headers=auth).status_code == 502
    assert not fake.calls


def test_approve_results_and_audit(client, auth, results):
    run = uuid4()
    assert client.post(f"/api/v1/tally-runs/{run}/approve", headers=auth).status_code == 204
    assert results.calls[-1] == ("approve", str(run))
    assert client.get(f"/api/v1/elections/{EID}/results", headers=auth).json()["run_number"] == 1
    assert client.get(f"/api/v1/organisations/{ORG}/audit?limit=10&before=50", headers=auth).json()[0]["event_type"] == "vote.accepted"
    assert results.calls[-1] == ("audit", 10, 50)
    for q in ("limit=0", "limit=201", "before=0"):
        assert client.get(f"/api/v1/organisations/{ORG}/audit?{q}", headers=auth).status_code == 422
    assert client.get(f"/api/v1/organisations/{ORG}/audit/verify", headers=auth).json() == {"ok": True, "checked": 7, "first_bad_id": None}


def test_results_are_404_until_published(client, auth, results):
    assert client.get(f"/api/v1/elections/{EID}/results", headers=auth).status_code == 404


async def test_results_repository_maps_rpc_and_table_calls():
    seen = []
    run_id = str(uuid4())

    def handler(request: httpx.Request) -> httpx.Response:
        name = request.url.path.rsplit("/", 1)[-1]
        seen.append((name, json.loads(request.content) if request.content else None, dict(request.url.params)))
        return httpx.Response(200, json={
            "record_tally_run": {"id": run_id, "run_number": 1},
            "list_tally_runs": [{"id": run_id, "run_number": 1, "created_at": NOW, "input_hash": "a" * 64, "ballot_count": 3, "tie_break": None,
                                 "result": {"complete": True}, "approved": True, "approved_at": NOW}],
            "published_result": None,
            "verify_audit_chain": {"ok": False, "checked": 4, "first_bad_id": 3},
            "audit_events": [{"id": 9, "event_type": "tally.approved", "entity_type": "election", "entity_id": "e", "actor_id": None,
                              "metadata": {"run": 1}, "created_at": NOW, "hash": "b" * 64}],
        }.get(name, {}))

    settings = Settings(app_env="test", supabase_url="https://x.supabase.co", supabase_anon_key="anon")
    user = AuthenticatedUser(id=uuid4(), email=None, token="user-jwt")
    repo = SupabaseResultsRepository(PostgrestClient(settings, transport=httpx.MockTransport(handler)))
    assert str(await repo.record_run(user, EID, "a" * 64, {"complete": True}, None)) == run_id
    assert seen[0][1] == {"p_election": str(EID), "p_hash": "a" * 64, "p_result": {"complete": True}, "p_tie_break": None}
    assert (await repo.list_runs(user, EID))[0].approved is True
    assert await repo.published(user, EID) is None
    assert (await repo.verify_audit(user, ORG)).first_bad_id == 3
    page = await repo.audit_page(user, ORG, 25, 100)
    assert page[0].metadata == {"run": 1} and seen[-1][2]["id"] == "lt.100" and seen[-1][2]["limit"] == "25" and seen[-1][2]["order"] == "id.desc"
