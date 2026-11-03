"""Highest-averages party-list proportional representation: D'Hondt and Sainte-Laguë.

Definition (both methods)
-------------------------
Each voter casts one vote for one list. A list that has already won ``s`` seats has the quotient
``votes / divisor(s)``. Seats are awarded one at a time to the list with the highest quotient.

* D'Hondt:       divisor(s) = s + 1        (1, 2, 3, 4 ...)
* Sainte-Laguë:  divisor(s) = 2 s + 1      (1, 3, 5, 7 ...)   -- the "pure" variant, no 1.4 modification

Electoral threshold (optional): a list takes part in the allocation only if
``votes * 100 >= threshold_percent * valid_votes``. Valid votes exclude blank and invalid ballots.

Ties: quotients are compared with exact integer cross-multiplication (no floating point).
If lists tie for the next seat and there are enough seats for all of them, all receive one
(the outcome equals any sequential order). If there are fewer seats than tied lists, the seats
are NOT assigned arbitrarily: the tied lists are reported in ``tied_for_last_seat`` and the
remaining seats are reported in ``unallocated_seats`` so the election's documented tie-break
procedure (e.g. a drawing of lots, recorded in the audit log) can be applied.
"""
from collections import Counter
from decimal import Decimal, InvalidOperation
from fractions import Fraction
from typing import Any, Callable, Mapping, Sequence

from .base import Ballot, CountResult


def _threshold(options: Mapping[str, Any] | None) -> Fraction:
    raw = (options or {}).get("threshold_percent", 0)
    try:
        value = Fraction(Decimal(str(raw)))
    except (InvalidOperation, ValueError):
        raise ValueError("threshold_percent must be a number") from None
    if not 0 <= value <= 100:
        raise ValueError("threshold_percent must be between 0 and 100")
    return value


class HighestAveragesMethod:
    key: str
    name: str
    description: str
    category = "proportional"
    ballot_type = "party_list"
    supports_threshold = True
    max_seats = None
    _divisor: Callable[[int], int]

    def validate(self, ballot: Ballot, candidates: Sequence[str], seats: int,
                 options: Mapping[str, Any] | None = None) -> str | None:
        sel = ballot.selections
        if len(sel) > 1:
            return "too_many_selections"
        if sel and sel[0] not in set(candidates):
            return "unknown_list"
        return None

    def count(self, ballots: Sequence[Ballot], candidates: Sequence[str], seats: int,
              options: Mapping[str, Any] | None = None) -> CountResult:
        if seats < 1:
            raise ValueError("seats must be at least 1")
        threshold = _threshold(options)
        votes = {c: 0 for c in candidates}
        invalid: Counter[str] = Counter()
        valid = blank = 0
        for b in ballots:
            reason = self.validate(b, candidates, seats, options)
            if reason:
                invalid[reason] += 1
            elif not b.selections:
                blank += 1
            else:
                valid += 1
                votes[b.selections[0]] += 1

        eligible = [c for c in candidates if votes[c] > 0 and votes[c] * 100 >= threshold * valid]
        below = tuple(c for c in candidates if votes[c] > 0 and c not in eligible)
        won = {c: 0 for c in candidates}
        log: list[dict[str, Any]] = []
        tied: tuple[str, ...] = ()
        remaining = seats if eligible else 0

        while remaining > 0:
            # quotient of list c = votes[c] / divisor(won[c]), compared as exact fractions
            quotients = {c: Fraction(votes[c], self._divisor(won[c])) for c in eligible}
            best = max(quotients.values())
            group = sorted(c for c, q in quotients.items() if q == best)
            if len(group) > remaining:
                tied = tuple(group)
                break
            for c in group:
                log.append({"seat": seats - remaining + 1, "list": c, "votes": votes[c],
                            "divisor": self._divisor(won[c]), "quotient": f"{best.numerator}/{best.denominator}"})
                won[c] += 1
                remaining -= 1

        unallocated = seats - sum(won.values())
        winners = tuple(c for c in candidates if won[c] > 0)
        return CountResult(
            method=self.key, seats=seats, tallies=votes, winners=winners, tied_for_last_seat=tied,
            valid_ballots=valid, blank_ballots=blank, invalid_ballots=sum(invalid.values()),
            invalid_reasons=dict(invalid), allocations={c: n for c, n in won.items() if n > 0},
            below_threshold=below, unallocated_seats=unallocated, allocation_log=tuple(log),
        )


class DHondtMethod(HighestAveragesMethod):
    key = "d_hondt"
    name = "D'Hondt (proportional)"
    description = "Party-list proportional representation. Seats go to the highest quotient votes ÷ (seats won + 1); slightly favours larger lists."
    _divisor = staticmethod(lambda seats_won: seats_won + 1)


class SainteLagueMethod(HighestAveragesMethod):
    key = "sainte_lague"
    name = "Sainte-Laguë (proportional)"
    description = "Party-list proportional representation. Seats go to the highest quotient votes ÷ (2 × seats won + 1); treats large and small lists more evenly."
    _divisor = staticmethod(lambda seats_won: 2 * seats_won + 1)
