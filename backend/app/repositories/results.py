"""Counting, approval, published results and audit access. Everything goes through the user's own JWT (RLS and SECURITY DEFINER functions)."""
from typing import Any, Protocol
from uuid import UUID

from app.schemas.api import AuditEventOut, AuditVerifyOut, PublishedResultOut, TallyRunOut
from app.security.auth import AuthenticatedUser
from .postgrest import PostgrestClient


class ResultsRepo(Protocol):
    async def tally_input(self, user: AuthenticatedUser, election: UUID) -> dict[str, Any]: ...
    async def record_run(self, user: AuthenticatedUser, election: UUID, input_hash: str, result: dict[str, Any], tie_break: dict[str, Any] | None) -> UUID: ...
    async def list_runs(self, user: AuthenticatedUser, election: UUID) -> list[TallyRunOut]: ...
    async def approve(self, user: AuthenticatedUser, run: UUID) -> None: ...
    async def published(self, user: AuthenticatedUser, election: UUID) -> PublishedResultOut | None: ...
    async def audit_page(self, user: AuthenticatedUser, org: UUID, limit: int, before: int | None) -> list[AuditEventOut]: ...
    async def verify_audit(self, user: AuthenticatedUser, org: UUID) -> AuditVerifyOut: ...


class SupabaseResultsRepository:
    def __init__(self, client: PostgrestClient) -> None:
        self.c = client

    async def tally_input(self, user, election):
        return await self.c.rpc("tally_input", user, {"p_election": str(election)})

    async def record_run(self, user, election, input_hash, result, tie_break):
        d = await self.c.rpc("record_tally_run", user, {"p_election": str(election), "p_hash": input_hash, "p_result": result, "p_tie_break": tie_break})
        return UUID(d["id"])

    async def list_runs(self, user, election):
        return [TallyRunOut(**r) for r in await self.c.rpc("list_tally_runs", user, {"p_election": str(election)})]

    async def approve(self, user, run):
        await self.c.rpc("approve_tally_run", user, {"p_run": str(run)})

    async def published(self, user, election):
        d = await self.c.rpc("published_result", user, {"p_election": str(election)})
        return PublishedResultOut(**d) if d else None

    async def audit_page(self, user, org, limit, before):
        params = {"select": "id,event_type,entity_type,entity_id,actor_id,metadata,created_at,hash", "organisation_id": f"eq.{org}",
                  "order": "id.desc", "limit": str(limit)}
        if before is not None:
            params["id"] = f"lt.{before}"
        return [AuditEventOut(**r) for r in await self.c.call("GET", "/audit_events", user, params=params)]

    async def verify_audit(self, user, org):
        return AuditVerifyOut(**await self.c.rpc("verify_audit_chain", user, {"p_org": str(org)}))
