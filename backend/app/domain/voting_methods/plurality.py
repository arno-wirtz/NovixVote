from collections import Counter
from typing import Any, Mapping, Sequence

from .base import Ballot, CountResult


class PluralityMethod:
    """First-past-the-post / block plurality.

    Each voter selects between 0 and `seats` distinct candidates; each selection is one vote.
    The `seats` candidates with the most votes win. A tie straddling the last seat is reported,
    never resolved arbitrarily. A ballot with no selections is counted as blank (not invalid).
    """

    key = "plurality"
    name = "Plurality (first-past-the-post)"
    category = "plurality"
    ballot_type = "candidate"
    supports_threshold = False
    max_seats = None
    description = "Voters pick up to the number of seats; the candidates with the most votes win."

    def validate(self, ballot: Ballot, candidates: Sequence[str], seats: int,
                 options: Mapping[str, Any] | None = None) -> str | None:
        sel = ballot.selections
        if len(sel) > seats:
            return "too_many_selections"
        if len(set(sel)) != len(sel):
            return "duplicate_selection"
        known = set(candidates)
        if any(s not in known for s in sel):
            return "unknown_candidate"
        return None

    def count(self, ballots: Sequence[Ballot], candidates: Sequence[str], seats: int,
              options: Mapping[str, Any] | None = None) -> CountResult:
        tallies = {c: 0 for c in candidates}
        invalid: Counter[str] = Counter()
        valid = blank = 0
        for b in ballots:
            reason = self.validate(b, candidates, seats)
            if reason:
                invalid[reason] += 1
            elif not b.selections:
                blank += 1
            else:
                valid += 1
                for s in b.selections:
                    tallies[s] += 1
        ranked = sorted(tallies.items(), key=lambda kv: (-kv[1], kv[0]))
        winners: list[str] = []
        tied: tuple[str, ...] = ()
        if ranked and seats > 0:
            cutoff = ranked[min(seats, len(ranked)) - 1][1]
            above = [c for c, v in ranked if v > cutoff]
            at = [c for c, v in ranked if v == cutoff]
            if cutoff == 0:
                winners = above
            elif len(above) + len(at) <= seats:
                winners = above + at
            else:
                winners, tied = above, tuple(at)
        return CountResult(self.key, seats, tallies, tuple(winners), tied, valid, blank,
                           sum(invalid.values()), dict(invalid))
