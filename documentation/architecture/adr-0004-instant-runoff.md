# ADR-0004: Majority/runoff as instant-runoff voting

## Decision
"Majority/runoff" is implemented as **instant-runoff voting (IRV, ranked choice) for a single seat**. It resolves a runoff inside one election using ranked ballots, so it fits the election lifecycle as built. **Two-round runoff** (a second election between the top two) needs linked follow-up elections, results-driven candidate selection and a second voter turnout; it is deferred until results exist (phase 6) and would reuse the same lifecycle.

## Ballot and counting rules
- Ballot: ordered, distinct candidates, most preferred first; partial rankings allowed; empty = blank; duplicate or unknown candidates = invalid.
- Each round every ballot counts for its highest-ranked remaining candidate; ballots with none left are **exhausted** and leave the count.
- A candidate wins with a majority of the **active** (non-exhausted) ballots, or when only one remains. A winner may therefore hold less than half of all ballots cast; the round log shows exactly how many were exhausted.
- Elimination: candidates with zero votes go together (cannot change the outcome); otherwise the lowest candidate goes.
- Tie for lowest: previous-round rule (the candidate with the lower tally in the most recent earlier round where they differ is eliminated). If they never differed, the engine **stops and reports the tie**. After a documented tie-break (e.g. drawing lots, recorded in the audit log) the outcome is passed back as `tie_break_order` and the count re-run; same ballots plus same order always gives the same result.
- `rounds` records tallies, exhausted ballots, eliminations and tie resolutions for every round so a count can be replayed by hand.

## Single-winner methods
`voting_methods.max_seats` (and the `max_seats` attribute in the engine registry) limit seats. IRV is 1. Enforced in the database (`validate_election`), the API and the wizard. Multi-winner ranked counting (STV) is a separate future method.

## Consistency guard
A backend test parses the SQL seed and fails if the engine registry and the `voting_methods` table disagree on keys, categories, ballot types, threshold support or seat limits.

## Why counting is not wired to elections yet
Counting needs stored ballots, which arrive with secure voting (phase 5) under the identity/ballot separation. The engine is ready and tested; phase 6 connects tabulation, tie-break recording and result approval to it.
