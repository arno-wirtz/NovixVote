import time
from datetime import datetime, timezone
from uuid import uuid4

import jwt
import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient

from app.api.deps import get_repository
from app.core.config import Settings, get_settings
from app.main import create_app
from app.schemas.api import (BallotOptionOut, ElectionOut, InvitationOut, MemberOut, MembershipOut, MyElectionOut, MyInvitationOut,
                             OrganisationOut, ReadinessItem, VoterPage, VotersResult)

SECRET = "test-secret-test-secret-test-secret-123"
NOW = datetime(2026, 11, 2, tzinfo=timezone.utc)


def make_token(sub=None, secret=SECRET, alg="HS256", exp_in=3600, aud="authenticated"):
    return jwt.encode({"sub": sub or str(uuid4()), "email": "a@b.test", "aud": aud,
                       "exp": int(time.time()) + exp_in}, secret, algorithm=alg)


class FakeRepo:
    """Records calls and returns canned data; authorisation itself is enforced (and tested) in the database."""

    def __init__(self):
        self.calls: list[tuple] = []
        self.role = "owner"

    def _election(self, data=None, status="draft", **kw):
        return ElectionOut(id=uuid4(), organisation_id=uuid4(), title=getattr(data, "title", "Council 2026"),
                           description=None, voting_method=getattr(data, "voting_method", "d_hondt"), seats=getattr(data, "seats", 5),
                           access="restricted", status=status, opens_at=None, closes_at=None, threshold_percent=None,
                           published_at=None, created_at=NOW, updated_at=NOW)

    async def list_organisations(self, user):
        return [OrganisationOut(id=uuid4(), name="Demo", slug="demo", role="owner")]

    async def create_organisation(self, user, name, slug):
        self.calls.append(("create_organisation", name, slug))
        return OrganisationOut(id=uuid4(), name=name, slug=slug, role="owner")

    async def membership(self, user, org):
        return None if self.role == "none" else MembershipOut(role=self.role, permissions=["org.read"])

    async def list_members(self, user, org):
        return [MemberOut(user_id=user.id, email="a@b.test", display_name=None, role="owner", status="active", joined_at=NOW)]

    async def change_role(self, user, org, member, role):
        self.calls.append(("change_role", str(member), role))

    async def remove_member(self, user, org, member):
        self.calls.append(("remove_member", str(member)))

    async def list_invitations(self, user, org):
        return []

    async def create_invitation(self, user, org, email, role):
        self.calls.append(("create_invitation", email, role))
        return InvitationOut(id=uuid4(), organisation_id=org, email=email, role=role, status="pending", expires_at=NOW, created_at=NOW)

    async def revoke_invitation(self, user, invitation):
        self.calls.append(("revoke_invitation", str(invitation)))

    async def my_invitations(self, user):
        return [MyInvitationOut(id=uuid4(), organisation_id=uuid4(), organisation_name="Demo", role="voter", expires_at=NOW, created_at=NOW)]

    async def respond_to_invitation(self, user, invitation, accept):
        self.calls.append(("respond", str(invitation), accept))

    async def list_elections(self, user, org):
        return [self._election()]

    async def get_election(self, user, election):
        raise HTTPException(404, "Election not found")

    async def create_election(self, user, org, data, settings):
        self.calls.append(("create_election", settings))
        return self._election(data)

    async def update_election(self, user, election, data, settings):
        self.calls.append(("update_election", settings))
        return self._election(data)

    async def delete_election(self, user, election):
        self.calls.append(("delete_election", str(election)))

    async def transition_election(self, user, election, to):
        self.calls.append(("transition", to))
        return self._election(status=to)


def _option(election, data):
    return BallotOptionOut(id=uuid4(), election_id=election, label=data.label, description=data.description, members=data.members, sort_order=1)


def _fake_extra(cls):
    async def my_elections(self, user):
        return [MyElectionOut(id=uuid4(), organisation_name="Demo", title="Council", status="scheduled", opens_at=None, closes_at=None)]

    async def ballot(self, user, election):
        return []

    async def add_option(self, user, election, data):
        self.calls.append(("add_option", data.label, data.members))
        return _option(election, data)

    async def update_option(self, user, option, data):
        self.calls.append(("update_option", str(option)))
        return _option(uuid4(), data)

    async def delete_option(self, user, option):
        self.calls.append(("delete_option", str(option)))

    async def reorder_options(self, user, election, ids):
        self.calls.append(("reorder", [str(i) for i in ids]))

    async def add_voters(self, user, election, voters):
        self.calls.append(("add_voters", [v.email for v in voters]))
        return VotersResult(added=len(voters), duplicates=0, invalid_count=0, invalid=[], total=len(voters))

    async def remove_voter(self, user, voter):
        self.calls.append(("remove_voter", str(voter)))

    async def voter_page(self, user, election, limit, offset, search):
        self.calls.append(("voter_page", limit, offset, search))
        return VoterPage(total=0, all_total=0, items=[])

    async def readiness(self, user, election):
        return [ReadinessItem(key="ballot", ok=False, label="The ballot has at least 2 lists", problem="Add at least 2 lists to the ballot before scheduling")]

    async def eligible(self, user, election):
        return True

    for f in (my_elections, ballot, add_option, update_option, delete_option, reorder_options, add_voters, remove_voter, voter_page, readiness, eligible):
        setattr(cls, f.__name__, f)
    return cls


_fake_extra(FakeRepo)


@pytest.fixture
def repo():
    return FakeRepo()


@pytest.fixture
def client(repo):
    app = create_app()
    app.dependency_overrides[get_settings] = lambda: Settings(
        app_env="test", supabase_url="https://x.supabase.co", supabase_anon_key="anon", supabase_jwt_secret=SECRET)
    app.dependency_overrides[get_repository] = lambda: repo
    return TestClient(app)


@pytest.fixture
def auth():
    return {"Authorization": f"Bearer {make_token()}"}
