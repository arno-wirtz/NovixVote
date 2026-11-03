"""Instant-runoff voting (ranked-choice majority), single seat.

Ballots
-------
A ballot is an ordered list of distinct candidates (most preferred first). Voters may rank as many or as few as they
like. An empty ballot is blank. Duplicates or unknown candidates make the ballot invalid.

Counting rules (all deterministic, nothing is decided by chance)
---------------------------------------------------------------
Each round, every ballot counts for its highest-ranked candidate who is still in the count. Ballots with no remaining
candidate are *exhausted* and leave the count. ``active`` is the number of non-exhausted ballots in that round.

1. A candidate wins when they hold a majority of the active ballots (``2 * votes > active``) or are the only one left.
2. Otherwise candidates with zero votes are eliminated together (this can't change the outcome); if there are none, the
   candidate with the fewest votes is eliminated and their ballots move to their next remaining preference.
3. Tie for fewest votes: compare the tied candidates' tallies in earlier rounds, most recent first; the one with the
   lower tally in the latest round where they differ is eliminated ("previous-round rule").
4. If they never differed, the count STOPS and reports the tie (``tied_for_last_seat``). The election's documented
   tie-break (e.g. drawing lots, recorded in the audit log) is then applied by passing its outcome back in as
   ``options["tie_break_order"]``: the tied candidate appearing first in that list is eliminated. Re-running the count
   with the same ballots and the same list always gives the same result.

The winner of a count with exhausted ballots holds a majority of the *remaining* ballots, not necessarily of all ballots
cast. ``rounds`` records every round (tallies, exhausted ballots, eliminations) so the count can be replayed by hand.
"""
from collections import Counter
from typing import Any, Mapping, Sequence

from .base import Ballot, CountResult


class InstantRunoffMethod:
    key = "irv"
    name = "Instant-runoff (ranked choice)"
    category = "majority"
    ballot_type = "ranked"
    supports_threshold = False
    max_seats = 1
    description = ("Voters rank candidates in order of preference. If nobody has a majority, the candidate with the fewest votes "
                   "is eliminated and their votes pass to the next choice, until someone has a majority. Elects one winner.")

    def validate(self, ballot: Ballot, candidates: Sequence[str], seats: int,
                 options: Mapping[str, Any] | None = None) -> str | None:
        sel = ballot.selections
        if len(set(sel)) != len(sel):
            return "duplicate_selection"
        known = set(candidates)
        if any(s not in known for s in sel):
            return "unknown_candidate"
        return None

    def count(self, ballots: Sequence[Ballot], candidates: Sequence[str], seats: int,
              options: Mapping[str, Any] | None = None) -> CountResult:
        if seats != 1:
            raise ValueError("Instant-runoff elects exactly one seat")
        tie_order = list((options or {}).get("tie_break_order", []))

        invalid: Counter[str] = Counter()
        rankings: list[tuple[str, ...]] = []
        blank = 0
        for b in ballots:
            reason = self.validate(b, candidates, seats, options)
            if reason:
                invalid[reason] += 1
            elif not b.selections:
                blank += 1
            else:
                rankings.append(b.selections)

        first = {c: 0 for c in candidates}
        for r in rankings:
            first[r[0]] += 1

        def result(winner: str | None, tied: tuple[str, ...], rounds: list[dict[str, Any]]) -> CountResult:
            return CountResult(
                method=self.key, seats=1, tallies=first, winners=(winner,) if winner else (), tied_for_last_seat=tied,
                valid_ballots=len(rankings), blank_ballots=blank, invalid_ballots=sum(invalid.values()),
                invalid_reasons=dict(invalid), unallocated_seats=0 if winner else 1, rounds=tuple(rounds))

        if not rankings:
            return result(None, (), [])

        continuing = list(candidates)
        history: list[dict[str, int]] = []
        rounds: list[dict[str, Any]] = []
        while True:
            tally = {c: 0 for c in continuing}
            exhausted = 0
            alive = set(continuing)
            for r in rankings:
                choice = next((c for c in r if c in alive), None)
                if choice is None:
                    exhausted += 1
                else:
                    tally[choice] += 1
            active = len(rankings) - exhausted
            history.append(tally)
            entry: dict[str, Any] = {"round": len(history), "tallies": dict(tally), "exhausted": exhausted, "active": active,
                                     "eliminated": [], "winner": None, "tie_resolution": None}
            rounds.append(entry)

            leader = max(tally, key=lambda c: (tally[c], -candidates.index(c)))
            if len(continuing) == 1 or 2 * tally[leader] > active:
                entry["winner"] = leader
                return result(leader, (), rounds)

            zeros = [c for c in continuing if tally[c] == 0]
            if zeros:
                entry["eliminated"] = zeros
                continuing = [c for c in continuing if c not in zeros]
                if not continuing:           # defensive: cannot happen because ballots exist and each names a candidate
                    return result(None, (), rounds)
                continue

            low = min(tally.values())
            lowest = [c for c in continuing if tally[c] == low]
            victim = lowest[0]
            if len(lowest) > 1:
                pool = lowest
                resolved = None
                for past in reversed(history[:-1]):                      # most recent earlier round first
                    pool_min = min(past.get(c, 0) for c in pool)
                    pool = [c for c in pool if past.get(c, 0) == pool_min]
                    if len(pool) == 1:
                        resolved = "previous_round"
                        break
                if len(pool) > 1:
                    pick = next((c for c in tie_order if c in pool), None)
                    if pick is None:
                        entry["tie"] = list(lowest)
                        return result(None, tuple(sorted(lowest)), rounds)
                    pool, resolved = [pick], "tie_break_order"
                victim = pool[0]
                entry["tie_resolution"] = resolved
            entry["eliminated"] = [victim]
            continuing = [c for c in continuing if c != victim]
