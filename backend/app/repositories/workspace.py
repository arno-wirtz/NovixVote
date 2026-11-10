"""Data access for workspaces, members, invitations and elections (all through RLS-enforced Supabase calls)."""
from datetime import datetime, timezone
from typing import Any, Protocol
from uuid import UUID

from fastapi import HTTPException, status

from app.schemas.api import (BallotOptionInput, BallotOptionOut, ElectionInput, ElectionOut, InvitationOut, MemberOut, MembershipOut,
                             MyElectionOut, MyInvitationOut, OrganisationOut, ReadinessItem, VoterInput, VotersResult, VoterPage)
from app.security.auth import AuthenticatedUser
from .postgrest import PostgrestClient


class Repository(Protocol):
    async def list_organisations(self, user: AuthenticatedUser) -> list[OrganisationOut]: ...
    async def create_organisation(self, user: AuthenticatedUser, name: str, slug: str) -> OrganisationOut: ...
    async def membership(self, user: AuthenticatedUser, org: UUID) -> MembershipOut | None: ...
    async def list_members(self, user: AuthenticatedUser, org: UUID) -> list[MemberOut]: ...
    async def change_role(self, user: AuthenticatedUser, org: UUID, member: UUID, role: str) -> None: ...
    async def remove_member(self, user: AuthenticatedUser, org: UUID, member: UUID) -> None: ...
    async def list_invitations(self, user: AuthenticatedUser, org: UUID) -> list[InvitationOut]: ...
    async def create_invitation(self, user: AuthenticatedUser, org: UUID, email: str, role: str) -> InvitationOut: ...
    async def revoke_invitation(self, user: AuthenticatedUser, invitation: UUID) -> None: ...
    async def my_invitations(self, user: AuthenticatedUser) -> list[MyInvitationOut]: ...
    async def respond_to_invitation(self, user: AuthenticatedUser, invitation: UUID, accept: bool) -> None: ...
    async def list_elections(self, user: AuthenticatedUser, org: UUID) -> list[ElectionOut]: ...
    async def get_election(self, user: AuthenticatedUser, election: UUID) -> ElectionOut: ...
    async def create_election(self, user: AuthenticatedUser, org: UUID, data: ElectionInput, settings: dict[str, Any]) -> ElectionOut: ...
    async def update_election(self, user: AuthenticatedUser, election: UUID, data: ElectionInput, settings: dict[str, Any]) -> ElectionOut: ...
    async def delete_election(self, user: AuthenticatedUser, election: UUID) -> None: ...
    async def transition_election(self, user: AuthenticatedUser, election: UUID, to: str) -> ElectionOut: ...
    async def my_elections(self, user: AuthenticatedUser) -> list[MyElectionOut]: ...
    async def ballot(self, user: AuthenticatedUser, election: UUID) -> list[BallotOptionOut]: ...
    async def add_option(self, user: AuthenticatedUser, election: UUID, data: BallotOptionInput) -> BallotOptionOut: ...
    async def update_option(self, user: AuthenticatedUser, option: UUID, data: BallotOptionInput) -> BallotOptionOut: ...
    async def delete_option(self, user: AuthenticatedUser, option: UUID) -> None: ...
    async def reorder_options(self, user: AuthenticatedUser, election: UUID, ids: list[UUID]) -> None: ...
    async def add_voters(self, user: AuthenticatedUser, election: UUID, voters: list[VoterInput]) -> VotersResult: ...
    async def remove_voter(self, user: AuthenticatedUser, voter: UUID) -> None: ...
    async def voter_page(self, user: AuthenticatedUser, election: UUID, limit: int, offset: int, search: str | None) -> VoterPage: ...
    async def readiness(self, user: AuthenticatedUser, election: UUID) -> list[ReadinessItem]: ...
    async def eligible(self, user: AuthenticatedUser, election: UUID) -> bool: ...


def _election(row: dict[str, Any]) -> ElectionOut:
    settings = row.get("settings") or {}
    return ElectionOut(**{k: row[k] for k in (
        "id", "organisation_id", "title", "description", "voting_method", "seats", "access", "status",
        "opens_at", "closes_at", "published_at", "created_at", "updated_at")},
        threshold_percent=settings.get("threshold_percent"),
        # Missing keys mean "default": votes can be changed while open, blank ballots are not allowed (same defaults as cast_vote()).
        allow_vote_change=bool(settings.get("allow_vote_change", True)),
        allow_blank_ballot=bool(settings.get("allow_blank_ballot", False)))


def _election_args(data: ElectionInput, settings: dict[str, Any]) -> dict[str, Any]:
    return {"p_title": data.title, "p_description": data.description, "p_method": data.voting_method,
            "p_seats": data.seats, "p_access": data.access,
            "p_opens": data.opens_at.isoformat() if data.opens_at else None,
            "p_closes": data.closes_at.isoformat() if data.closes_at else None, "p_settings": settings}


class SupabaseRepository:
    def __init__(self, client: PostgrestClient) -> None:
        self.c = client

    # ---- organisations ----
    async def list_organisations(self, user):
        rows = await self.c.call("GET", "/organisation_members", user, params={
            "select": "role,organisations(id,name,slug)", "user_id": f"eq.{user.id}", "status": "eq.active", "order": "created_at.asc"})
        return [OrganisationOut(role=r["role"], **r["organisations"]) for r in rows if r.get("organisations")]

    async def create_organisation(self, user, name, slug):
        d = await self.c.rpc("create_organisation", user, {"p_name": name, "p_slug": slug})
        return OrganisationOut(id=d["id"], name=d["name"], slug=d["slug"], role="owner")

    # ---- members ----
    async def membership(self, user, org):
        rows = await self.c.rpc("my_membership", user, {"p_org": str(org)})
        return MembershipOut(**rows[0]) if rows else None

    async def list_members(self, user, org):
        rows = await self.c.call("GET", "/organisation_members", user, params={
            "select": "user_id,role,status,created_at,profiles(email,display_name)",
            "organisation_id": f"eq.{org}", "order": "created_at.asc"})
        return [MemberOut(user_id=r["user_id"], email=(r.get("profiles") or {}).get("email"),
                          display_name=(r.get("profiles") or {}).get("display_name"),
                          role=r["role"], status=r["status"], joined_at=r["created_at"]) for r in rows]

    async def change_role(self, user, org, member, role):
        await self.c.rpc("change_member_role", user, {"p_org": str(org), "p_user": str(member), "p_role": role})

    async def remove_member(self, user, org, member):
        await self.c.rpc("remove_member", user, {"p_org": str(org), "p_user": str(member)})

    # ---- invitations ----
    async def list_invitations(self, user, org):
        rows = await self.c.call("GET", "/organisation_invitations", user, params={
            "select": "id,organisation_id,email,role,status,expires_at,created_at", "organisation_id": f"eq.{org}",
            "status": "eq.pending", "expires_at": f"gt.{datetime.now(timezone.utc).isoformat()}", "order": "created_at.desc"})
        return [InvitationOut(**r) for r in rows]

    async def create_invitation(self, user, org, email, role):
        return InvitationOut(**await self.c.rpc("create_invitation", user, {"p_org": str(org), "p_email": email, "p_role": role}))

    async def revoke_invitation(self, user, invitation):
        await self.c.rpc("revoke_invitation", user, {"p_id": str(invitation)})

    async def my_invitations(self, user):
        return [MyInvitationOut(**r) for r in await self.c.rpc("my_invitations", user)]

    async def respond_to_invitation(self, user, invitation, accept):
        await self.c.rpc("respond_to_invitation", user, {"p_id": str(invitation), "p_accept": accept})

    # ---- elections ----
    async def _advance(self, user) -> None:
        try:
            await self.c.rpc("advance_elections", user)   # time-based open/close; idempotent
        except HTTPException:
            pass  # reads must still work if the housekeeping call fails

    async def list_elections(self, user, org):
        await self._advance(user)
        rows = await self.c.call("GET", "/elections", user, params={"select": "*", "organisation_id": f"eq.{org}", "order": "created_at.desc"})
        return [_election(r) for r in rows]

    async def get_election(self, user, election):
        await self._advance(user)
        rows = await self.c.call("GET", "/elections", user, params={"select": "*", "id": f"eq.{election}"})
        if not rows:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Election not found")
        org_name = await self.c.rpc("election_organisation_name", user, {"p_election": str(election)})
        return _election(rows[0]).model_copy(update={"organisation_name": org_name})

    async def create_election(self, user, org, data, settings):
        return _election(await self.c.rpc("create_election", user, {"p_org": str(org), **_election_args(data, settings)}))

    async def update_election(self, user, election, data, settings):
        return _election(await self.c.rpc("update_election", user, {"p_id": str(election), **_election_args(data, settings)}))

    async def delete_election(self, user, election):
        await self.c.rpc("delete_election", user, {"p_id": str(election)})

    async def transition_election(self, user, election, to):
        return _election(await self.c.rpc("transition_election", user, {"p_id": str(election), "p_to": to}))

    async def my_elections(self, user):
        return [MyElectionOut(**r) for r in await self.c.rpc("my_eligible_elections", user)]

    # ---- ballot ----
    async def ballot(self, user, election):
        rows = await self.c.call("GET", "/ballot_options", user, params={
            "select": "id,election_id,label,description,members,sort_order", "election_id": f"eq.{election}", "order": "sort_order.asc,created_at.asc"})
        return [BallotOptionOut(**r) for r in rows]

    async def add_option(self, user, election, data):
        return BallotOptionOut(**await self.c.rpc("add_ballot_option", user, {
            "p_election": str(election), "p_label": data.label, "p_description": data.description, "p_members": data.members}))

    async def update_option(self, user, option, data):
        return BallotOptionOut(**await self.c.rpc("update_ballot_option", user, {
            "p_id": str(option), "p_label": data.label, "p_description": data.description, "p_members": data.members}))

    async def delete_option(self, user, option):
        await self.c.rpc("delete_ballot_option", user, {"p_id": str(option)})

    async def reorder_options(self, user, election, ids):
        await self.c.rpc("reorder_ballot_options", user, {"p_election": str(election), "p_ids": [str(i) for i in ids]})

    # ---- voters / eligibility ----
    async def add_voters(self, user, election, voters):
        return VotersResult(**await self.c.rpc("add_election_voters", user, {
            "p_election": str(election), "p_voters": [v.model_dump() for v in voters]}))

    async def remove_voter(self, user, voter):
        await self.c.rpc("remove_election_voter", user, {"p_id": str(voter)})

    async def voter_page(self, user, election, limit, offset, search):
        return VoterPage(**await self.c.rpc("election_voter_page", user, {
            "p_election": str(election), "p_limit": limit, "p_offset": offset, "p_search": search}))

    async def readiness(self, user, election):
        return [ReadinessItem(**r) for r in await self.c.rpc("election_readiness", user, {"p_election": str(election)})]

    async def eligible(self, user, election):
        return bool(await self.c.rpc("is_eligible_voter", user, {"p_election": str(election)}))
