from app.domain.voting_methods import Ballot, registry

M = registry.get("plurality")
C = ["ana", "ben", "caro"]


def B(*s):
    return Ballot(tuple(s))


def test_clear_winner():
    r = M.count([B("ana"), B("ana"), B("ben")], C, 1)
    assert r.winners == ("ana",) and not r.requires_tiebreak
    assert r.tallies == {"ana": 2, "ben": 1, "caro": 0} and r.valid_ballots == 3


def test_tie_for_single_seat_is_reported_not_resolved():
    r = M.count([B("ana"), B("ben")], C, 1)
    assert r.winners == () and set(r.tied_for_last_seat) == {"ana", "ben"} and r.requires_tiebreak


def test_tie_below_the_cutoff_does_not_matter():
    r = M.count([B("ana"), B("ana"), B("ben"), B("caro")], C, 1)
    assert r.winners == ("ana",) and not r.requires_tiebreak


def test_multi_seat_boundary_tie():
    r = M.count([B("ana", "ben"), B("ana", "caro")], C, 2)
    assert r.winners == ("ana",) and set(r.tied_for_last_seat) == {"ben", "caro"}


def test_invalid_and_blank_ballots_are_separated():
    r = M.count([B("ana"), B(), B("zed"), B("ana", "ben"), B("ben", "ben")], C, 1)
    assert (r.valid_ballots, r.blank_ballots, r.invalid_ballots) == (1, 1, 3)
    assert r.invalid_reasons == {"unknown_candidate": 1, "too_many_selections": 1, "duplicate_selection": 1} or \
        r.invalid_reasons["unknown_candidate"] == 1


def test_no_votes_means_no_winner_and_no_tie():
    r = M.count([], C, 1)
    assert r.winners == () and not r.requires_tiebreak


def test_more_seats_than_candidates():
    r = M.count([B("ana", "ben")], ["ana", "ben"], 5)
    assert set(r.winners) == {"ana", "ben"}
