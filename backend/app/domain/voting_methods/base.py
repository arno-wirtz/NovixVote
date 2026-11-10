"""Voting-method contract. Pure Python: no FastAPI, database or UI imports allowed in this package."""
from dataclasses import dataclass, field
from typing import Any, Mapping, Protocol, Sequence


@dataclass(frozen=True)
class Ballot:
    """An anonymous ballot. `selections` is ordered (rank order for ranked methods)."""
    selections: tuple[str, ...]


@dataclass(frozen=True)
class CountResult:
    method: str
    seats: int
    tallies: dict[str, int]
    winners: tuple[str, ...]
    # Candidates tied for the final seat(s). The engine never breaks ties silently;
    # the election's configured tie-break procedure must be applied and audited separately.
    tied_for_last_seat: tuple[str, ...] = ()
    valid_ballots: int = 0
    blank_ballots: int = 0
    invalid_ballots: int = 0
    invalid_reasons: dict[str, int] = field(default_factory=dict)
    # Seat-based (proportional) methods only:
    allocations: dict[str, int] = field(default_factory=dict)          # seats won per list
    below_threshold: tuple[str, ...] = ()                              # lists excluded by the electoral threshold
    unallocated_seats: int = 0                                         # seats left open by an unresolved tie / no eligible list
    allocation_log: tuple[dict[str, Any], ...] = ()                    # one entry per seat: reproducible audit trail
    # Elimination methods (instant-runoff): one entry per round, so a count can be replayed by hand.
    rounds: tuple[dict[str, Any], ...] = ()

    @property
    def requires_tiebreak(self) -> bool:
        return bool(self.tied_for_last_seat)


class VotingMethod(Protocol):
    key: str
    name: str
    category: str  # plurality | majority | proportional
    description: str
    ballot_type: str  # candidate | ranked | party_list
    supports_threshold: bool
    max_seats: int | None  # None = no limit; 1 = single-winner method

    def validate(self, ballot: Ballot, candidates: Sequence[str], seats: int,
                 options: Mapping[str, Any] | None = None) -> str | None:
        """Return None if valid, otherwise a stable machine-readable reason code."""

    def count(self, ballots: Sequence[Ballot], candidates: Sequence[str], seats: int,
              options: Mapping[str, Any] | None = None) -> CountResult: ...
