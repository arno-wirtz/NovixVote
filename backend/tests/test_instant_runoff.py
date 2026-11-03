import random

import pytest

from app.domain.voting_methods import Ballot, InstantRunoffMethod, registry

M = InstantRunoffMethod()
C = ["A", "B", "C", "D"]


def bs(*groups):
    """bs((5, 'A', 'B'), ...) -> 5 ballots ranking A then B."""
    return [Ballot(tuple(g[1:])) for g in groups for _ in range(g[0])]


def test_registered_with_single_seat_limit():
    m = registry.get("irv")
    assert m.ballot_type == "ranked" and m.max_seats == 1 and not m.supports_threshold


def test_first_round_majority_needs_no_elimination():
    r = M.count(bs((6, "A"), (3, "B"), (1, "C")), C, 1)
    assert r.winners == ("A",) and len(r.rounds) == 1 and r.rounds[0]["eliminated"] == []


def test_transfers_decide_the_winner():
    # A leads 40-35-25 but C's voters prefer B.
    r = M.count(bs((40, "A"), (35, "B"), (25, "C", "B")), C, 1)
    assert r.winners == ("B",)
    assert [rd["eliminated"] for rd in r.rounds[:2]] == [["D"], ["C"]]   # D has zero votes: eliminated first, together with nobody else
    assert r.rounds[-1]["tallies"] == {"A": 40, "B": 60} and r.tallies == {"A": 40, "B": 35, "C": 25, "D": 0}


def test_exhausted_ballots_leave_the_count():
    r = M.count(bs((40, "A"), (35, "B"), (25, "C")), C, 1)
    last = r.rounds[-1]
    assert r.winners == ("A",) and last["active"] == 75 and last["exhausted"] == 25   # 40 of 75 remaining: a majority of those still in the count
    assert r.valid_ballots == 100


def test_zero_vote_candidates_are_eliminated_together():
    r = M.count(bs((2, "A"), (2, "B")), ["A", "B", "C", "D", "E"], 1, {"tie_break_order": ["B"]})   # no majority in round 1
    assert r.rounds[0]["eliminated"] == ["C", "D", "E"]                      # all zero-vote candidates leave together, no tie-break needed
    assert r.rounds[1]["eliminated"] == ["B"] and r.winners == ("A",)


def test_tie_for_elimination_resolved_by_previous_round():
    # Round 1: A5 B5 C3 D2. D out (-> C). Round 2: A5 B5 C5 tie for last; C had fewest in round 1 -> C out -> A wins.
    r = M.count(bs((5, "A"), (5, "B"), (3, "C", "A"), (2, "D", "C", "A")), C, 1)
    assert r.winners == ("A",) and not r.requires_tiebreak
    assert r.rounds[1]["tie_resolution"] == "previous_round" and r.rounds[1]["eliminated"] == ["C"]


def test_unresolvable_tie_stops_and_can_be_resolved_by_recorded_tie_break():
    ballots = bs((2, "A"), (2, "B"))
    stalled = M.count(ballots, ["A", "B"], 1)
    assert stalled.winners == () and stalled.requires_tiebreak and stalled.tied_for_last_seat == ("A", "B") and stalled.unallocated_seats == 1
    resolved = M.count(ballots, ["A", "B"], 1, {"tie_break_order": ["B", "A"]})   # lots drawn: B is eliminated
    assert resolved.winners == ("A",) and resolved.rounds[0]["tie_resolution"] == "tie_break_order"
    assert M.count(ballots, ["A", "B"], 1, {"tie_break_order": ["B", "A"]}) == resolved           # deterministic


def test_invalid_blank_and_empty():
    r = M.count([Ballot(("A", "A")), Ballot(("Z",)), Ballot(()), Ballot(("A", "B"))], C, 1)
    assert (r.valid_ballots, r.blank_ballots, r.invalid_ballots) == (1, 1, 2) and r.winners == ("A",)
    assert r.invalid_reasons == {"duplicate_selection": 1, "unknown_candidate": 1}
    none = M.count([Ballot(())], C, 1)
    assert none.winners == () and not none.requires_tiebreak


def test_single_candidate_wins():
    assert M.count(bs((1, "A")), ["A"], 1).winners == ("A",)


def test_only_one_seat():
    with pytest.raises(ValueError):
        M.count([], C, 2)


def random_ballots(rng, n=80):
    out = []
    for _ in range(n):
        ranking = rng.sample(C, rng.randint(0, len(C)))
        out.append(Ballot(tuple(ranking)))
    return out


def test_properties_on_random_elections():
    rng = random.Random(7)
    for _ in range(400):
        ballots = random_ballots(rng)
        r = M.count(ballots, C, 1)
        # order of ballots never matters
        shuffled = ballots[:]; rng.shuffle(shuffled)
        assert M.count(shuffled, C, 1).winners == r.winners and M.count(shuffled, C, 1).tied_for_last_seat == r.tied_for_last_seat
        for rd in r.rounds:
            assert sum(rd["tallies"].values()) == rd["active"]                    # every non-exhausted ballot counts exactly once
        if r.winners:
            last = r.rounds[-1]
            assert last["winner"] == r.winners[0]
            assert 2 * last["tallies"][r.winners[0]] > last["active"] or len(last["tallies"]) == 1
        else:
            assert r.requires_tiebreak or r.valid_ballots == 0
        if r.requires_tiebreak:   # supplying any complete tie-break order always finishes the count
            full = M.count(ballots, C, 1, {"tie_break_order": C})
            assert len(full.winners) == 1
