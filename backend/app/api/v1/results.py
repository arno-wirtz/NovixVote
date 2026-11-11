from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, status

from app.api.deps import get_results_repository
from app.domain.tabulation import ballot_set_hash, run_count
from app.repositories.results import ResultsRepo
from app.schemas.api import AuditEventOut, AuditVerifyOut, PublishedResultOut, TallyRequest, TallyRunOut
from app.security.auth import AuthenticatedUser, get_current_user

router = APIRouter(tags=["results"])


@router.post("/elections/{election_id}/tally", response_model=TallyRunOut, status_code=status.HTTP_201_CREATED)
async def run_tally(election_id: UUID, data: TallyRequest, user: AuthenticatedUser = Depends(get_current_user),
                    repo: ResultsRepo = Depends(get_results_repository)):
    """Counts the closed ballot set with the election's voting method and stores the result as a new, permanent count.

    The database only accepts the count if it was made from exactly the ballots it holds (hash check), so a stale or invented
    ballot set is rejected. Anyone can re-run the engine on the same ballots and compare."""
    inp = await repo.tally_input(user, election_id)
    ballots = inp["ballots"]
    local_hash = ballot_set_hash(ballots)
    if local_hash != inp["hash"]:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, "The ballots could not be verified. Try again")
    tie_break = data.tie_break.model_dump() if data.tie_break else None
    try:
        result = run_count(inp["method"], inp["options"], ballots, inp["seats"], inp.get("settings") or {}, tie_break)
    except ValueError as e:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, str(e)) from None
    run_id = await repo.record_run(user, election_id, local_hash, result, tie_break)
    return next(r for r in await repo.list_runs(user, election_id) if r.id == run_id)


@router.get("/elections/{election_id}/tally-runs", response_model=list[TallyRunOut])
async def list_runs(election_id: UUID, user: AuthenticatedUser = Depends(get_current_user), repo: ResultsRepo = Depends(get_results_repository)):
    return await repo.list_runs(user, election_id)


@router.post("/tally-runs/{run_id}/approve", status_code=status.HTTP_204_NO_CONTENT)
async def approve_run(run_id: UUID, user: AuthenticatedUser = Depends(get_current_user), repo: ResultsRepo = Depends(get_results_repository)):
    await repo.approve(user, run_id)
    return None


@router.get("/elections/{election_id}/results", response_model=PublishedResultOut)
async def published_result(election_id: UUID, user: AuthenticatedUser = Depends(get_current_user), repo: ResultsRepo = Depends(get_results_repository)):
    """The approved count of a published election, for anyone who can see the election. 404 until it is published."""
    r = await repo.published(user, election_id)
    if r is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Results haven't been published")
    return r


@router.get("/organisations/{org_id}/audit", response_model=list[AuditEventOut])
async def audit_events(org_id: UUID, limit: int = Query(50, ge=1, le=200), before: int | None = Query(None, ge=1),
                       user: AuthenticatedUser = Depends(get_current_user), repo: ResultsRepo = Depends(get_results_repository)):
    return await repo.audit_page(user, org_id, limit, before)


@router.get("/organisations/{org_id}/audit/verify", response_model=AuditVerifyOut)
async def verify_audit(org_id: UUID, user: AuthenticatedUser = Depends(get_current_user), repo: ResultsRepo = Depends(get_results_repository)):
    return await repo.verify_audit(user, org_id)
