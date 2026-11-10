from fastapi import APIRouter

from . import elections, system, voting, workspaces

router = APIRouter(prefix="/api/v1")
router.include_router(system.router)
router.include_router(workspaces.router)
router.include_router(elections.router)
router.include_router(voting.router)
