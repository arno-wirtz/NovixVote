from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, status

from app.api.deps import get_repository
from app.repositories.workspace import Repository
from app.schemas.api import (InvitationCreate, InvitationOut, MemberOut, MembershipOut, MyInvitationOut,
                             OrganisationCreate, OrganisationOut, RoleChange)
from app.security.auth import AuthenticatedUser, get_current_user

router = APIRouter(tags=["workspaces"])


@router.get("/organisations", response_model=list[OrganisationOut])
async def list_organisations(user: AuthenticatedUser = Depends(get_current_user), repo: Repository = Depends(get_repository)):
    return await repo.list_organisations(user)


@router.post("/organisations", response_model=OrganisationOut, status_code=status.HTTP_201_CREATED)
async def create_organisation(payload: OrganisationCreate, user: AuthenticatedUser = Depends(get_current_user),
                              repo: Repository = Depends(get_repository)):
    return await repo.create_organisation(user, payload.name, payload.slug or "")


@router.get("/organisations/{org_id}/me", response_model=MembershipOut)
async def my_membership(org_id: UUID, user: AuthenticatedUser = Depends(get_current_user), repo: Repository = Depends(get_repository)):
    m = await repo.membership(user, org_id)
    if m is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Workspace not found")
    return m


@router.get("/organisations/{org_id}/members", response_model=list[MemberOut])
async def list_members(org_id: UUID, user: AuthenticatedUser = Depends(get_current_user), repo: Repository = Depends(get_repository)):
    if await repo.membership(user, org_id) is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Workspace not found")
    return await repo.list_members(user, org_id)


@router.patch("/organisations/{org_id}/members/{member_id}", status_code=status.HTTP_204_NO_CONTENT)
async def change_role(org_id: UUID, member_id: UUID, payload: RoleChange, user: AuthenticatedUser = Depends(get_current_user),
                      repo: Repository = Depends(get_repository)):
    await repo.change_role(user, org_id, member_id, payload.role)
    return None


@router.delete("/organisations/{org_id}/members/{member_id}", status_code=status.HTTP_204_NO_CONTENT)
async def remove_member(org_id: UUID, member_id: UUID, user: AuthenticatedUser = Depends(get_current_user),
                        repo: Repository = Depends(get_repository)):
    await repo.remove_member(user, org_id, member_id)
    return None


@router.get("/organisations/{org_id}/invitations", response_model=list[InvitationOut])
async def list_invitations(org_id: UUID, user: AuthenticatedUser = Depends(get_current_user), repo: Repository = Depends(get_repository)):
    return await repo.list_invitations(user, org_id)


@router.post("/organisations/{org_id}/invitations", response_model=InvitationOut, status_code=status.HTTP_201_CREATED)
async def create_invitation(org_id: UUID, payload: InvitationCreate, user: AuthenticatedUser = Depends(get_current_user),
                            repo: Repository = Depends(get_repository)):
    return await repo.create_invitation(user, org_id, payload.email, payload.role)


@router.delete("/invitations/{invitation_id}", status_code=status.HTTP_204_NO_CONTENT)
async def revoke_invitation(invitation_id: UUID, user: AuthenticatedUser = Depends(get_current_user), repo: Repository = Depends(get_repository)):
    await repo.revoke_invitation(user, invitation_id)
    return None


@router.get("/invitations/mine", response_model=list[MyInvitationOut])
async def my_invitations(user: AuthenticatedUser = Depends(get_current_user), repo: Repository = Depends(get_repository)):
    return await repo.my_invitations(user)


@router.post("/invitations/{invitation_id}/accept", status_code=status.HTTP_204_NO_CONTENT)
async def accept_invitation(invitation_id: UUID, user: AuthenticatedUser = Depends(get_current_user), repo: Repository = Depends(get_repository)):
    await repo.respond_to_invitation(user, invitation_id, True)
    return None


@router.post("/invitations/{invitation_id}/decline", status_code=status.HTTP_204_NO_CONTENT)
async def decline_invitation(invitation_id: UUID, user: AuthenticatedUser = Depends(get_current_user), repo: Repository = Depends(get_repository)):
    await repo.respond_to_invitation(user, invitation_id, False)
    return None
