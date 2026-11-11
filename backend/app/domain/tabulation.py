"""Counting orchestration: stored ballots -> voting engine -> a replayable, JSON-serialisable result.

Pure Python (no FastAPI, no database). The engine never breaks ties silently; this module applies a *documented, recorded* tie-break
(who decided, how, in what order) and marks the result incomplete until every tie that matters is resolved.
"""
import hashlib
from typing import Any, Mapping, Sequence

from .voting_methods import Ballot, registry


def ballot_set_hash(ballots: Sequence[Sequence[str]]) -> str:
    """sha256 of one line per ballot (option ids, comma separated, rank order kept), lines sorted bytewise.
    Must equal public.ballot_set_hash() in the database."""
    lines = sorted(",".join(b) for b in ballots)
    return hashlib.sha256("\n".join(lines).encode("utf-8")).hexdigest()


def run_count(method_key: str, options: Sequence[Mapping[str, str]], ballots: Sequence[Sequence[str]], seats: int,
              settings: Mapping[str, Any] | None = None, tie_break: Mapping[str, Any] | None = None) -> dict[str, Any]:
    """Counts `ballots` (lists of option ids). `tie_break` = {"order": [labels, most favoured first], "method": ..., "note": ...}.

    The tie-break order decides only genuine ties: instant-runoff passes it to the engine (it eliminates the first tied
    candidate in that order); for plurality and highest-averages methods the first tied candidates in the order take the
    seats still open. Anything the order does not settle stays unresolved and the result is marked ``complete = False``.
    """
    settings = settings or {}
    method = registry.get(method_key)
    label_of = {o["id"]: o["label"] for o in options}
    candidates = [o["label"] for o in options]
    try:
        labelled = [Ballot(tuple(label_of[i] for i in b)) for b in ballots]
    except KeyError:
        raise ValueError("A ballot refers to an option that isn't on this election's ballot") from None
    order = list((tie_break or {}).get("order", []))
    if any(c not in candidates for c in order) or len(set(order)) != len(order):
        raise ValueError("The tie-break order must list each candidate at most once, using names on the ballot")

    opts: dict[str, Any] = {}
    if method.supports_threshold:
        opts["threshold_percent"] = settings.get("threshold_percent", 0)
    if method_key == "irv":
        opts["tie_break_order"] = order
    res = method.count(labelled, candidates, seats, opts or None)

    winners = list(res.winners)
    allocations = dict(res.allocations)
    tied = list(res.tied_for_last_seat)
    unallocated = res.unallocated_seats
    resolution: dict[str, Any] | None = None
    if tied and method_key != "irv":
        remaining = unallocated if method.category == "proportional" else seats - len(winners)
        chosen = [c for c in order if c in tied][:remaining]
        if remaining > 0 and len(chosen) == remaining:
            if method.category == "proportional":
                for c in chosen:
                    allocations[c] = allocations.get(c, 0) + 1
                winners = [c for c in candidates if allocations.get(c)]
                unallocated -= remaining
            else:
                winners += chosen
            resolution = {"tied": tied, "seats": remaining, "awarded": chosen}
            tied = []
    elif method_key == "irv" and not tied and any(r.get("tie_resolution") == "tie_break_order" for r in res.rounds):
        resolution = {"applied_in_rounds": [r["round"] for r in res.rounds if r.get("tie_resolution") == "tie_break_order"]}

    return {
        "method": method.key, "category": method.category, "ballot_type": method.ballot_type, "seats": seats, "candidates": candidates,
        "tallies": dict(res.tallies), "winners": winners, "allocations": allocations, "below_threshold": list(res.below_threshold),
        "valid_ballots": res.valid_ballots, "blank_ballots": res.blank_ballots, "invalid_ballots": res.invalid_ballots,
        "invalid_reasons": dict(res.invalid_reasons), "allocation_log": list(res.allocation_log), "rounds": list(res.rounds),
        "tied_for_last_seat": tied, "unallocated_seats": unallocated, "tie_resolution": resolution, "complete": not tied,
    }
