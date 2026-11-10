"""Voting data access. Kept apart from the workspace repository: voting is its own security domain.

Everything goes through SECURITY DEFINER functions with the user's own JWT, so the database decides eligibility, election state
and ballot validity. Never log request bodies or responses of these calls: they contain selections and receipts.
"""
from typing import Protocol
from uuid import UUID

from app.schemas.api import MyVoteOut, TurnoutOut, VoteReceiptOut
from app.security.auth import AuthenticatedUser
from .postgrest import PostgrestClient


class VotingRepo(Protocol):
    async def cast(self, user: AuthenticatedUser, election: UUID, selections: list[UUID]) -> VoteReceiptOut: ...
    async def my_vote(self, user: AuthenticatedUser, election: UUID) -> MyVoteOut: ...
    async def turnout(self, user: AuthenticatedUser, election: UUID) -> TurnoutOut: ...
    async def verify_receipt(self, user: AuthenticatedUser, election: UUID, receipt: str) -> bool: ...


class SupabaseVotingRepository:
    def __init__(self, client: PostgrestClient) -> None:
        self.c = client

    async def cast(self, user, election, selections):
        return VoteReceiptOut(**await self.c.rpc("cast_vote", user, {
            "p_election": str(election), "p_selections": [str(s) for s in selections]}))

    async def my_vote(self, user, election):
        return MyVoteOut(**await self.c.rpc("my_vote", user, {"p_election": str(election)}))

    async def turnout(self, user, election):
        return TurnoutOut(**await self.c.rpc("election_turnout", user, {"p_election": str(election)}))

    async def verify_receipt(self, user, election, receipt):
        return bool(await self.c.rpc("verify_receipt", user, {"p_election": str(election), "p_receipt": receipt}))
