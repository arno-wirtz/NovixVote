import random
from fractions import Fraction

import pytest

from app.domain.voting_methods import Ballot, DHondtMethod, SainteLagueMethod, registry

LISTS = ["A", "B", "C", "D"]


def ballots(**votes):
    return [Ballot((k,)) for k, n in votes.items() for _ in range(n)]


def seats_of(method_key, votes, seats, **opts):
    r = registry.get(method_key).count(ballots(**votes), list(votes), seats, opts or None)
    return r


def test_registered():
    assert {"d_hondt", "sainte_lague"} <= {m.key for m in registry.all_methods()}


def test_dhondt_textbook_example():
    # 100/80/30/20 votes, 8 seats. Quotients: A 100,50,33.3,25  B 80,40,26.7  C 30  -> A4 B3 C1 D0
    r = seats_of("d_hondt", dict(A=100, B=80, C=30, D=20), 8)
    assert r.allocations == {"A": 4, "B": 3, "C": 1} and not r.requires_tiebreak and r.unallocated_seats == 0
    assert [e["list"] for e in r.allocation_log][:3] == ["A", "B", "A"]


def test_sainte_lague_textbook_example_and_tie_with_room():
    # divisors 1,3,5,7: A 100,33.3,20  B 80,26.7,16  C 30  D 20 (ties A's 3rd seat, both fit) -> A3 B3 C1 D1
    r = seats_of("sainte_lague", dict(A=100, B=80, C=30, D=20), 8)
    assert r.allocations == {"A": 3, "B": 3, "C": 1, "D": 1} and not r.requires_tiebreak


def test_methods_differ_in_favour_of_larger_lists():
    d = seats_of("d_hondt", dict(A=100, B=80, C=30, D=20), 8).allocations
    s = seats_of("sainte_lague", dict(A=100, B=80, C=30, D=20), 8).allocations
    assert d["A"] > s["A"] and s.get("D", 0) > d.get("D", 0)


@pytest.mark.parametrize("key", ["d_hondt", "sainte_lague"])
def test_tie_for_last_seat_is_reported_not_resolved(key):
    r = seats_of(key, dict(A=10, B=10), 1)
    assert r.allocations == {} and set(r.tied_for_last_seat) == {"A", "B"} and r.unallocated_seats == 1


def test_partial_allocation_before_unresolved_tie():
    r = seats_of("d_hondt", dict(A=100, B=60, C=60), 2)  # A takes seat 1; B,C tie for seat 2 (A's next quotient is only 50)
    assert r.allocations == {"A": 1} and set(r.tied_for_last_seat) == {"B", "C"} and r.unallocated_seats == 1


def test_threshold_excludes_small_lists_and_boundary_is_inclusive():
    r = seats_of("d_hondt", dict(A=95, B=5), 4, threshold_percent=5)   # B is exactly 5% -> kept
    assert "B" not in r.below_threshold
    r = seats_of("d_hondt", dict(A=96, B=4), 4, threshold_percent=5)   # 4% -> excluded
    assert r.below_threshold == ("B",) and r.allocations == {"A": 4}


def test_decimal_threshold_is_exact():
    r = seats_of("sainte_lague", dict(A=9975, B=25), 3, threshold_percent="0.25")  # 0.25% exactly
    assert "B" not in r.below_threshold


def test_blank_and_invalid_ballots_do_not_count_toward_threshold_base():
    bs = ballots(A=95, B=5) + [Ballot(())] * 50 + [Ballot(("A", "B")), Ballot(("Z",))]
    r = DHondtMethod().count(bs, ["A", "B"], 4, {"threshold_percent": 5})
    assert (r.valid_ballots, r.blank_ballots, r.invalid_ballots) == (100, 50, 2) and "B" not in r.below_threshold


def test_no_votes_and_nobody_over_threshold():
    r = DHondtMethod().count([], ["A", "B"], 3)
    assert r.allocations == {} and r.unallocated_seats == 3 and not r.requires_tiebreak


def test_invalid_options_and_seats():
    with pytest.raises(ValueError):
        DHondtMethod().count([], ["A"], 1, {"threshold_percent": 101})
    with pytest.raises(ValueError):
        DHondtMethod().count([], ["A"], 1, {"threshold_percent": "abc"})
    with pytest.raises(ValueError):
        DHondtMethod().count([], ["A"], 0)


@pytest.mark.parametrize("method", [DHondtMethod(), SainteLagueMethod()])
def test_highest_averages_property_on_random_elections(method):
    rng = random.Random(2026)
    for _ in range(300):
        lists = [f"L{i}" for i in range(rng.randint(2, 8))]
        votes = {l: rng.randint(0, 300) for l in lists}
        seats = rng.randint(1, 30)
        r = method.count(ballots(**votes), lists, seats)
        if not sum(votes.values()):
            continue
        assert sum(r.allocations.values()) + r.unallocated_seats == seats
        if r.requires_tiebreak:
            continue
        assert r.unallocated_seats == 0
        div = method._divisor
        last_won = min(Fraction(votes[l], div(n - 1)) for l, n in r.allocations.items())
        next_best = max(Fraction(votes[l], div(r.allocations.get(l, 0))) for l in lists)
        assert last_won >= next_best  # nobody left out has a higher next quotient than a seat actually awarded
