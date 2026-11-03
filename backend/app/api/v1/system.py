from datetime import datetime, timezone

from fastapi import APIRouter, Depends

from app.core.config import Settings, get_settings
from app.domain.voting_methods import registry
from app.schemas.api import HealthResponse, MeResponse, VotingMethodOut
from app.security.auth import AuthenticatedUser, get_current_user

router = APIRouter()


@router.get("/health", response_model=HealthResponse, tags=["system"])
def health(settings: Settings = Depends(get_settings)) -> HealthResponse:
    return HealthResponse(status="ok", service=settings.app_name, version=settings.app_version,
                          environment=settings.app_env, supabase_configured=settings.supabase_configured,
                          time=datetime.now(timezone.utc))


@router.get("/auth/me", response_model=MeResponse, tags=["auth"])
def me(user: AuthenticatedUser = Depends(get_current_user)) -> MeResponse:
    return MeResponse(id=user.id, email=user.email)


@router.get("/voting-methods", response_model=list[VotingMethodOut], tags=["voting"])
def voting_methods(_: AuthenticatedUser = Depends(get_current_user)) -> list[VotingMethodOut]:
    return [VotingMethodOut(key=m.key, name=m.name, description=m.description, category=m.category,
                            ballot_type=m.ballot_type, supports_threshold=m.supports_threshold, max_seats=m.max_seats)
            for m in registry.all_methods()]
