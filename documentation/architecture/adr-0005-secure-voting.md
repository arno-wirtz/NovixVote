# ADR-0005: Secure voting, voting rules and vote changes

## Voting rules set by the person in charge
Stored in `elections.settings`, validated by `validate_election()`, editable only while the election is a draft (so they are frozen once it is scheduled).
| Rule | Default | Meaning |
|---|---|---|
| `allow_blank_ballot` | `false` | `false`: a vote must select at least one option. `true`: a blank ballot is accepted and counted as blank. |
| `allow_vote_change` | `true` | `true`: a voter may replace their vote while the election is open. `false`: one vote, final once submitted. |
The wizard offers both as explicit choices; the voter page states which rules apply. A missing key means "default" everywhere (database, API, UI).

## Data separation
| Table | Holds | Never holds |
|---|---|---|
| `vote_participation` | election, user, change count | ballot id, selections, timestamps |
| `ballots` | election, selections (option ids), receipt hash, optional slot | user, email, session, any timestamp |
| `election_vote_keys` | per-election 32-byte secret (vote-change elections only) | |
API roles have no grants and no policies on these tables. All access is through `cast_vote`, `my_vote`, `verify_receipt`, `election_turnout` (SECURITY DEFINER, the caller's own JWT). Eligibility, election state, selection limits and option membership are checked in the database, not the browser.

## Casting a vote (`cast_vote`)
One transaction: lock (organisation, then election row `FOR SHARE`), check eligibility and `open` state, validate selections, insert participation, insert or replace the ballot, append an audit event. A concurrent manual close waits for in-flight votes; the duplicate-vote guard is the `vote_participation` primary key, so two simultaneous submissions cannot both count.
- Non-ranked selections are stored sorted, so tick order cannot fingerprint a voter. Ranked ballots keep their order.
- The audit event is `vote.accepted` with no actor and no selections. Ballots carry no timestamps, so audit timing cannot be matched to a ballot.
- The receipt is 128+ random bits shown once; only its SHA-256 is stored. It proves inclusion, not the choice. After a change, only the newest receipt verifies.

## Changing votes versus ballot secrecy (honest trade-off)
Replacing a vote requires finding the voter's ballot. In elections that allow changes, each ballot carries `slot = sha256(secret || election || user)` where `secret` is a per-election random key held in `election_vote_keys`.
- **While open:** someone with database-owner access and the key could link a voter to their ballot. The voter themselves can read their own current choice (`my_vote`) so they can change it.
- **At close** (trigger `elections_close_cleanup`, covers manual and scheduled closing): the key is deleted and every slot is set to NULL. From then on ballots are unlinkable to voters.
- **Not protected:** physical row order and WAL/backups taken while open can still carry linkage. Elections that need stronger secrecy should set `allow_vote_change = false`; high-assurance elections still need the blind-credential protocol and independent review described in ADR-0001 item 8. The wizard says this in plain words.

## Known limits (deliberate, tracked)
- Ballot selections are stored as plain option ids; encryption at rest with external key custody is a phase 6/8 item.
- All votes in one organisation serialise on the audit-chain lock (a few ms each). Fine for organisational elections; revisit before very large ones.
- Rate limiting of the vote and receipt endpoints is not implemented yet (phase 7/8, with the production gateway).
- Public elections still cannot guarantee one person, one account.

## Not in this phase
Counting wired to stored ballots, tie-break recording, result approval and display (phase 6).
