# ADR-0006: Counting, tie-breaks, approval, publication and audit verification

## Who counts what
The voting engine (`backend/app/domain/voting_methods`) stays pure. `backend/app/domain/tabulation.py` orchestrates: option ids -> names, engine call, documented tie-break, JSON result. FastAPI fetches the closed ballot set with the caller's own JWT, counts, and stores the result through the database.

## Flow
1. **Voting closes** (manually or by schedule). Vote-change keys and slots are destroyed (ADR-0005).
2. **Count** (`POST /elections/{id}/tally`, needs `election.manage`): `tally_input()` returns the ballots shuffled and anonymous, with a SHA-256 of the exact set. The backend recomputes the hash itself and refuses on mismatch.
3. **Record** (`record_tally_run()`): the database accepts a count only if its hash equals the hash of the ballots it holds. Counts are append-only (triggers); a recount is a new run, never an edit. Each is audited (`tally.recorded`).
4. **Ties are never broken silently.** The engine reports them and the count is marked `complete = false`. The election's documented procedure is recorded as a tie-break (`method`, `note`, `order`) and the count is run again. The tie-break order decides only genuine ties: instant-runoff eliminates the first tied candidate in the order; plurality and highest-averages methods award the open seats to the first tied candidates in the order. The note and order are stored with the count and shown with the result.
5. **Approve** (`approve_tally_run()`, needs `results.approve`, i.e. owners): only the latest, complete count of the current ballot set, once per election (`tally.approved`). Managers can count but cannot approve, so one person need not control every step.
6. **Publish** (existing `closed -> published` move): a trigger refuses it when ballots exist and no count is approved. An election nobody voted in has nothing to count and can still be published.
7. **See results**: `published_result()` gives eligible voters and members only the approved count of a published election. Counts and approvals are not readable by API roles directly.

## Reproducibility
The stored input hash identifies the ballot set. Anyone with the same ballots can re-run the engine (same method, settings, tie-break) and must get the same result; tests assert this regardless of ballot order.
Canonical form: one line per ballot, option ids joined by commas (rank order kept), lines sorted bytewise, joined by newlines, SHA-256 hex. Implemented identically in SQL (`ballot_set_hash`) and Python (`ballot_set_hash`).

## Audit trail
Votes are audited as `vote.accepted` with no actor and no selections. The Audit tab (owners and admins, `audit.read`) lists events and runs `verify_audit_chain()`, which recomputes the per-workspace hash chain. It relies on every session using the same timezone setting (the database default; UTC on Supabase): do not change the database timezone on a live system.

## Known limits (deliberate)
- The count result is computed outside the database, so the database cannot prove the arithmetic; it proves *which ballots* were counted. Verification is by independent re-count.
- A hash chain held only in this database does not prove it was never rewritten by someone who controls it. Signed checkpoints and external anchoring are not built yet; they need key custody decided first.
- Ballots are still stored unencrypted (option ids only, no identity). Encryption at rest with external key custody is not built yet.
- Two-round runoff, largest-remainder and STV are not implemented.
- Results export (CSV/PDF) is not built.
