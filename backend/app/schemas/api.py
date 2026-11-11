import re
from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

SLUG_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")


def slugify(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")[:48].strip("-")


class HealthResponse(BaseModel):
    status: str
    service: str
    version: str
    environment: str
    supabase_configured: bool
    time: datetime


class MeResponse(BaseModel):
    id: UUID
    email: str | None


class OrganisationCreate(BaseModel):
    name: str = Field(min_length=2, max_length=80)
    slug: str | None = Field(default=None, max_length=48)

    @field_validator("name")
    @classmethod
    def _strip(cls, v: str) -> str:
        v = v.strip()
        if len(v) < 2:
            raise ValueError("Name must be at least 2 characters")
        return v

    @model_validator(mode="after")
    def _slug(self) -> "OrganisationCreate":
        slug = self.slug or slugify(self.name)
        if len(slug) < 3 or not SLUG_RE.match(slug):
            raise ValueError("Slug must be 3-48 characters: lowercase letters, numbers and single hyphens")
        self.slug = slug
        return self


class OrganisationOut(BaseModel):
    id: UUID
    name: str
    slug: str
    role: str


class VotingMethodOut(BaseModel):
    key: str
    name: str
    description: str
    category: str
    ballot_type: str
    supports_threshold: bool
    max_seats: int | None = None


# ---------------- phase 2: members, invitations, elections ----------------
from typing import Annotated, Literal  # noqa: E402

from pydantic import AwareDatetime  # noqa: E402

InvitableRole = Literal["admin", "election_manager", "voter"]
AnyRole = Literal["owner", "admin", "election_manager", "voter"]
ElectionStatus = Literal["draft", "scheduled", "open", "closed", "published"]
_EMAIL = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


class MembershipOut(BaseModel):
    role: AnyRole
    permissions: list[str]


class MemberOut(BaseModel):
    user_id: UUID
    email: str | None
    display_name: str | None
    role: AnyRole
    status: str
    joined_at: datetime


class RoleChange(BaseModel):
    role: AnyRole


class InvitationCreate(BaseModel):
    email: str = Field(max_length=254)
    role: InvitableRole

    @field_validator("email")
    @classmethod
    def _email(cls, v: str) -> str:
        v = v.strip().lower()
        if not _EMAIL.match(v):
            raise ValueError("Enter a valid email address")
        return v


class InvitationOut(BaseModel):
    id: UUID
    organisation_id: UUID
    email: str
    role: AnyRole
    status: str
    expires_at: datetime
    created_at: datetime


class MyInvitationOut(BaseModel):
    id: UUID
    organisation_id: UUID
    organisation_name: str
    role: AnyRole
    expires_at: datetime
    created_at: datetime


class ElectionInput(BaseModel):
    title: str = Field(min_length=3, max_length=120)
    description: str | None = Field(default=None, max_length=2000)
    voting_method: str = Field(min_length=1, max_length=40)
    seats: int = Field(ge=1, le=100)
    access: Literal["restricted", "public"] = "restricted"
    opens_at: AwareDatetime | None = None
    closes_at: AwareDatetime | None = None
    threshold_percent: float | None = Field(default=None, ge=0, le=100)
    # Voting rules chosen by the person in charge. None = leave unset, the database defaults apply
    # (a vote must select at least one option; votes can be changed while the election is open).
    allow_vote_change: bool | None = None
    allow_blank_ballot: bool | None = None

    @field_validator("title")
    @classmethod
    def _title(cls, v: str) -> str:
        v = v.strip()
        if len(v) < 3:
            raise ValueError("Title must be at least 3 characters")
        return v

    @model_validator(mode="after")
    def _window(self) -> "ElectionInput":
        if self.opens_at and self.closes_at and self.closes_at <= self.opens_at:
            raise ValueError("Closing time must be after opening time")
        return self


class ElectionOut(BaseModel):
    id: UUID
    organisation_id: UUID
    title: str
    description: str | None
    voting_method: str
    seats: int
    access: str
    status: ElectionStatus
    opens_at: datetime | None
    closes_at: datetime | None
    threshold_percent: float | None
    allow_vote_change: bool = True
    allow_blank_ballot: bool = False
    published_at: datetime | None
    created_at: datetime
    updated_at: datetime
    organisation_name: str | None = None


class TransitionRequest(BaseModel):
    to: ElectionStatus


# ---------------- phase 3: ballot, voters, readiness, eligibility ----------------
class BallotOptionInput(BaseModel):
    label: str = Field(min_length=1, max_length=120)
    description: str | None = Field(default=None, max_length=500)
    members: list[Annotated[str, Field(min_length=1, max_length=120)]] = Field(default_factory=list, max_length=100)

    @field_validator("label")
    @classmethod
    def _label(cls, v: str) -> str:
        v = v.strip()
        if not v:
            raise ValueError("Name can't be empty")
        return v


class BallotOptionOut(BaseModel):
    id: UUID
    election_id: UUID
    label: str
    description: str | None
    members: list[str]
    sort_order: int


class BallotOrder(BaseModel):
    ids: list[UUID] = Field(max_length=200)


class VoterInput(BaseModel):
    # Deliberately lenient: malformed rows are reported one by one by the database instead of rejecting the whole upload.
    email: str = Field(max_length=320)
    name: str | None = Field(default=None, max_length=400)


class VotersAdd(BaseModel):
    voters: list[VoterInput] = Field(min_length=1, max_length=1000)


class InvalidVoterRow(BaseModel):
    row: int
    email: str
    reason: str


class VotersResult(BaseModel):
    added: int
    duplicates: int
    invalid_count: int
    invalid: list[InvalidVoterRow]
    total: int


class VoterOut(BaseModel):
    id: UUID
    email: str
    name: str | None
    created_at: datetime


class VoterPage(BaseModel):
    total: int
    all_total: int
    items: list[VoterOut]


class ReadinessItem(BaseModel):
    key: str
    ok: bool
    label: str
    problem: str


class EligibilityOut(BaseModel):
    eligible: bool


class MyElectionOut(BaseModel):
    id: UUID
    organisation_name: str
    title: str
    status: ElectionStatus
    opens_at: datetime | None
    closes_at: datetime | None


# ---------------- phase 5: voting ----------------
class VoteInput(BaseModel):
    """Selections only. The voter's identity comes from the verified token, never from the body."""
    model_config = ConfigDict(extra="forbid")
    # Ballot option ids. Empty = blank ballot (only accepted when the election allows it). For ranked ballots the order is the ranking.
    selections: list[UUID] = Field(default_factory=list, max_length=200)


class VoteReceiptOut(BaseModel):
    receipt: str
    changed: bool


class MyVoteOut(BaseModel):
    voted: bool
    can_change: bool
    selections: list[UUID] | None = None   # only while the election is open and vote changes are allowed


class TurnoutOut(BaseModel):
    voted: int
    eligible: int | None = None            # None for public elections (there is no voter list)


class ReceiptCheckIn(BaseModel):
    model_config = ConfigDict(extra="forbid")
    receipt: str = Field(pattern=r"^[0-9a-fA-F]{64}$")


class ReceiptCheckOut(BaseModel):
    included: bool


# ---------------- phase 6: counting, results, audit ----------------
from typing import Any  # noqa: E402


class TieBreakIn(BaseModel):
    """A documented tie-break. `order` lists the tied candidates, most favoured first (e.g. the order lots were drawn in)."""
    model_config = ConfigDict(extra="forbid")
    method: Literal["lots", "agreed_order", "other"]
    note: str = Field(min_length=3, max_length=500)      # who decided and how: stored with the count and shown with the result
    order: list[str] = Field(min_length=1, max_length=200)


class TallyRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    tie_break: TieBreakIn | None = None


class TallyRunOut(BaseModel):
    id: UUID
    run_number: int
    created_at: datetime
    input_hash: str
    ballot_count: int
    tie_break: dict[str, Any] | None = None
    result: dict[str, Any]
    approved: bool = False
    approved_at: datetime | None = None


class PublishedResultOut(BaseModel):
    ballot_count: int
    run_number: int | None = None
    approved_at: datetime | None = None
    input_hash: str | None = None
    tie_break: dict[str, Any] | None = None
    result: dict[str, Any] | None = None      # None when the election was published with no ballots cast


class AuditEventOut(BaseModel):
    id: int
    event_type: str
    entity_type: str | None = None
    entity_id: str | None = None
    actor_id: UUID | None = None
    metadata: dict[str, Any] = Field(default_factory=dict)
    created_at: datetime
    hash: str


class AuditVerifyOut(BaseModel):
    ok: bool
    checked: int
    first_bad_id: int | None = None
