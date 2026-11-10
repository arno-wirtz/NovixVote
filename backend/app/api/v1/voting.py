from uuid import UUID

from fastapi import APIRouter, Depends

from app.api.deps import get_voting_repository
from app.repositories.voting import VotingRepo
from app.schemas.api import MyVoteOut, ReceiptCheckIn, ReceiptCheckOut, TurnoutOut, VoteInput, VoteReceiptOut
from app.security.auth import AuthenticatedUser, get_current_user

router = APIRouter(tags=["voting"])


@router.post("/elections/{election_id}/vote", response_model=VoteReceiptOut)
async def cast_vote(election_id: UUID, data: VoteInput, user: AuthenticatedUser = Depends(get_current_user),
                    repo: VotingRepo = Depends(get_voting_repository)):
    """Casts (or, if the election allows it, replaces) the caller's vote. Eligibility, state and ballot rules are enforced in the database."""
    return await repo.cast(user, election_id, data.selections)


@router.get("/elections/{election_id}/vote", response_model=MyVoteOut)
async def my_vote(election_id: UUID, user: AuthenticatedUser = Depends(get_current_user), repo: VotingRepo = Depends(get_voting_repository)):
    return await repo.my_vote(user, election_id)


@router.get("/elections/{election_id}/turnout", response_model=TurnoutOut)
async def turnout(election_id: UUID, user: AuthenticatedUser = Depends(get_current_user), repo: VotingRepo = Depends(get_voting_repository)):
    return await repo.turnout(user, election_id)


@router.post("/elections/{election_id}/receipt/verify", response_model=ReceiptCheckOut)
async def verify_receipt(election_id: UUID, data: ReceiptCheckIn, user: AuthenticatedUser = Depends(get_current_user),
                         repo: VotingRepo = Depends(get_voting_repository)):
    """POST (not GET) so the receipt never appears in URLs or access logs."""
    return ReceiptCheckOut(included=await repo.verify_receipt(user, election_id, data.receipt))
