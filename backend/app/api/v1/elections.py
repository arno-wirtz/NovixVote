from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, status

from app.api.deps import get_repository
from app.domain.voting_methods import registry
from app.repositories.workspace import Repository
from app.schemas.api import (BallotOptionInput, BallotOptionOut, BallotOrder, EligibilityOut, ElectionInput, ElectionOut, MyElectionOut,
                             ReadinessItem, TransitionRequest, VotersAdd, VotersResult, VoterPage)
from app.security.auth import AuthenticatedUser, get_current_user

router = APIRouter(tags=["elections"])


def election_settings(data: ElectionInput) -> dict[str, Any]:
    """Checks the voting method against the engine registry and builds the election settings (method options + voting rules)."""
    try:
        method = registry.get(data.voting_method)
    except KeyError:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "Unknown voting method") from None
    if method.max_seats is not None and data.seats > method.max_seats:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT,
                            f"This voting system elects exactly {method.max_seats} seat{'' if method.max_seats == 1 else 's'}")
    settings: dict[str, Any] = {}
    if method.supports_threshold:
        settings["threshold_percent"] = data.threshold_percent or 0
    elif data.threshold_percent:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "This voting method has no electoral threshold")
    # Voting rules are only sent when the client chose them; the database validates them again and applies defaults to the rest.
    if data.allow_vote_change is not None:
        settings["allow_vote_change"] = data.allow_vote_change
    if data.allow_blank_ballot is not None:
        settings["allow_blank_ballot"] = data.allow_blank_ballot
    return settings


@router.get("/organisations/{org_id}/elections", response_model=list[ElectionOut])
async def list_elections(org_id: UUID, user: AuthenticatedUser = Depends(get_current_user), repo: Repository = Depends(get_repository)):
    if await repo.membership(user, org_id) is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Workspace not found")
    return await repo.list_elections(user, org_id)


@router.post("/organisations/{org_id}/elections", response_model=ElectionOut, status_code=status.HTTP_201_CREATED)
async def create_election(org_id: UUID, data: ElectionInput, user: AuthenticatedUser = Depends(get_current_user),
                          repo: Repository = Depends(get_repository)):
    return await repo.create_election(user, org_id, data, election_settings(data))


@router.get("/elections/mine", response_model=list[MyElectionOut])
async def my_elections(user: AuthenticatedUser = Depends(get_current_user), repo: Repository = Depends(get_repository)):
    """Restricted elections the signed-in user is on the voter list of (public elections are reachable by link only)."""
    return await repo.my_elections(user)


@router.get("/elections/{election_id}", response_model=ElectionOut)
async def get_election(election_id: UUID, user: AuthenticatedUser = Depends(get_current_user), repo: Repository = Depends(get_repository)):
    return await repo.get_election(user, election_id)


@router.put("/elections/{election_id}", response_model=ElectionOut)
async def update_election(election_id: UUID, data: ElectionInput, user: AuthenticatedUser = Depends(get_current_user),
                          repo: Repository = Depends(get_repository)):
    return await repo.update_election(user, election_id, data, election_settings(data))


@router.delete("/elections/{election_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_election(election_id: UUID, user: AuthenticatedUser = Depends(get_current_user), repo: Repository = Depends(get_repository)):
    await repo.delete_election(user, election_id)
    return None


@router.post("/elections/{election_id}/transition", response_model=ElectionOut)
async def transition_election(election_id: UUID, payload: TransitionRequest, user: AuthenticatedUser = Depends(get_current_user),
                              repo: Repository = Depends(get_repository)):
    return await repo.transition_election(user, election_id, payload.to)


# ---------------- ballot ----------------
@router.get("/elections/{election_id}/ballot", response_model=list[BallotOptionOut])
async def get_ballot(election_id: UUID, user: AuthenticatedUser = Depends(get_current_user), repo: Repository = Depends(get_repository)):
    return await repo.ballot(user, election_id)


@router.post("/elections/{election_id}/ballot/options", response_model=BallotOptionOut, status_code=status.HTTP_201_CREATED)
async def add_option(election_id: UUID, data: BallotOptionInput, user: AuthenticatedUser = Depends(get_current_user),
                     repo: Repository = Depends(get_repository)):
    return await repo.add_option(user, election_id, data)


@router.put("/ballot/options/{option_id}", response_model=BallotOptionOut)
async def update_option(option_id: UUID, data: BallotOptionInput, user: AuthenticatedUser = Depends(get_current_user),
                        repo: Repository = Depends(get_repository)):
    return await repo.update_option(user, option_id, data)


@router.delete("/ballot/options/{option_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_option(option_id: UUID, user: AuthenticatedUser = Depends(get_current_user), repo: Repository = Depends(get_repository)):
    await repo.delete_option(user, option_id)
    return None


@router.put("/elections/{election_id}/ballot/order", status_code=status.HTTP_204_NO_CONTENT)
async def reorder_options(election_id: UUID, data: BallotOrder, user: AuthenticatedUser = Depends(get_current_user),
                          repo: Repository = Depends(get_repository)):
    await repo.reorder_options(user, election_id, data.ids)
    return None


# ---------------- voters, eligibility, readiness ----------------
@router.get("/elections/{election_id}/voters", response_model=VoterPage)
async def voter_page(election_id: UUID, limit: int = Query(50, ge=1, le=200), offset: int = Query(0, ge=0),
                     search: str | None = Query(None, max_length=100), user: AuthenticatedUser = Depends(get_current_user),
                     repo: Repository = Depends(get_repository)):
    return await repo.voter_page(user, election_id, limit, offset, search)


@router.post("/elections/{election_id}/voters", response_model=VotersResult)
async def add_voters(election_id: UUID, data: VotersAdd, user: AuthenticatedUser = Depends(get_current_user),
                     repo: Repository = Depends(get_repository)):
    return await repo.add_voters(user, election_id, data.voters)


@router.delete("/voters/{voter_id}", status_code=status.HTTP_204_NO_CONTENT)
async def remove_voter(voter_id: UUID, user: AuthenticatedUser = Depends(get_current_user), repo: Repository = Depends(get_repository)):
    await repo.remove_voter(user, voter_id)
    return None


@router.get("/elections/{election_id}/readiness", response_model=list[ReadinessItem])
async def readiness(election_id: UUID, user: AuthenticatedUser = Depends(get_current_user), repo: Repository = Depends(get_repository)):
    return await repo.readiness(user, election_id)


@router.get("/elections/{election_id}/eligibility", response_model=EligibilityOut)
async def eligibility(election_id: UUID, user: AuthenticatedUser = Depends(get_current_user), repo: Repository = Depends(get_repository)):
    return EligibilityOut(eligible=await repo.eligible(user, election_id))
