import hashlib
import json
import random

import pytest

from app.domain.tabulation import ballot_set_hash, run_count

OPTS = [{"id": f"id-{n}", "label": n} for n in ("Ana", "Ben", "Cara")]
ID = {o["label"]: o["id"] for o in OPTS}


def bs(**votes):
    """bs(Ana=2, Ben=1) -> ballots of option ids; a tuple value ranks several options."""
    out = []
    for name, n in votes.items():
        out += [[ID[x] for x in name.split("_")]] * n
    return out


def test_hash_is_order_independent_and_matches_the_documented_format():
    a, b = ["x", "y"], ["z"]
    assert ballot_set_hash([a, b]) == ballot_set_hash([b, a])
    assert ballot_set_hash([a, b]) == hashlib.sha256(b"x,y\nz").hexdigest()
    assert ballot_set_hash([["y", "x"]]) != ballot_set_hash([a])                    # rank order inside a ballot matters
    assert ballot_set_hash([]) == hashlib.sha256(b"").hexdigest()
    assert ballot_set_hash([[], []]) == hashlib.sha256(b"\n").hexdigest()          # blank ballots are counted lines


def test_plurality_maps_ids_to_names_and_counts_blanks():
    r = run_count("plurality", OPTS, bs(Ana=3, Ben=1) + [[]], 1)
    assert r["winners"] == ["Ana"] and r["tallies"] == {"Ana": 3, "Ben": 1, "Cara": 0}
    assert r["blank_ballots"] == 1 and r["valid_ballots"] == 4 and r["complete"] is True and r["tie_resolution"] is None
    json.dumps(r)                                                                  # stored as jsonb: must serialise


def test_plurality_tie_is_incomplete_until_a_recorded_order_settles_it():
    ballots = bs(Ana=2, Ben=2, Cara=1)
    r = run_count("plurality", OPTS, ballots, 1)
    assert r["complete"] is False and set(r["tied_for_last_seat"]) == {"Ana", "Ben"} and r["winners"] == []
    r = run_count("plurality", OPTS, ballots, 1, tie_break={"order": ["Ben", "Ana"], "method": "lots", "note": "drawn"})
    assert r["complete"] is True and r["winners"] == ["Ben"] and r["tie_resolution"]["awarded"] == ["Ben"]
    r = run_count("plurality", OPTS, ballots, 1, tie_break={"order": ["Cara"], "method": "lots", "note": "drawn"})   # order doesn't mention the tied pair
    assert r["complete"] is False


def test_multi_seat_plurality_boundary_tie():
    r = run_count("plurality", OPTS, bs(Ana=3, Ben=2, Cara=2), 2)
    assert r["winners"] == ["Ana"] and set(r["tied_for_last_seat"]) == {"Ben", "Cara"}
    r = run_count("plurality", OPTS, bs(Ana=3, Ben=2, Cara=2), 2, tie_break={"order": ["Cara", "Ben"]})
    assert r["winners"] == ["Ana", "Cara"] and r["complete"]


def test_dhondt_tie_for_last_seat_resolved_by_order():
    ballots = bs(Ana=10, Ben=10)
    r = run_count("d_hondt", OPTS, ballots, 1)
    assert not r["complete"] and r["unallocated_seats"] == 1 and r["allocations"] == {}
    r = run_count("d_hondt", OPTS, ballots, 1, tie_break={"order": ["Ben", "Ana"]})
    assert r["complete"] and r["allocations"] == {"Ben": 1} and r["winners"] == ["Ben"] and r["unallocated_seats"] == 0


def test_dhondt_threshold_setting_is_passed_to_the_engine():
    r = run_count("d_hondt", OPTS, bs(Ana=96, Ben=4), 4, settings={"threshold_percent": 5})
    assert r["below_threshold"] == ["Ben"] and r["allocations"] == {"Ana": 4}


def test_instant_runoff_tie_resolved_by_recorded_order():
    ballots = bs(Ana=2, Ben=2)
    r = run_count("irv", OPTS[:2], ballots, 1)
    assert not r["complete"] and set(r["tied_for_last_seat"]) == {"Ana", "Ben"}
    r = run_count("irv", OPTS[:2], ballots, 1, tie_break={"order": ["Ben", "Ana"]})       # Ben is eliminated
    assert r["complete"] and r["winners"] == ["Ana"] and r["tie_resolution"]["applied_in_rounds"] == [1]


def test_ranked_ballots_keep_their_order():
    r = run_count("irv", OPTS, bs(Ana=2, Ben_Cara=1, Cara_Ben=1, Cara_Ana=3), 1)
    assert r["complete"] and len(r["winners"]) == 1 and r["rounds"]


def test_bad_inputs_are_rejected():
    with pytest.raises(ValueError):
        run_count("plurality", OPTS, [["nope"]], 1)
    with pytest.raises(ValueError):
        run_count("plurality", OPTS, bs(Ana=1), 1, tie_break={"order": ["Zed"]})
    with pytest.raises(ValueError):
        run_count("plurality", OPTS, bs(Ana=1), 1, tie_break={"order": ["Ana", "Ana"]})


@pytest.mark.parametrize("method,seats", [("plurality", 1), ("d_hondt", 3), ("sainte_lague", 3), ("irv", 1)])
def test_recount_is_deterministic_whatever_the_ballot_order(method, seats):
    rng = random.Random(11)
    ballots = [rng.sample([o["id"] for o in OPTS], rng.randint(0, 3)) for _ in range(60)]
    if method != "irv":
        ballots = [b[:1] for b in ballots]
    first = run_count(method, OPTS, ballots, seats, tie_break={"order": ["Cara", "Ben", "Ana"]})
    for _ in range(5):
        shuffled = ballots[:]
        rng.shuffle(shuffled)
        assert run_count(method, OPTS, shuffled, seats, tie_break={"order": ["Cara", "Ben", "Ana"]}) == first
    assert ballot_set_hash(ballots) == ballot_set_hash(shuffled)
