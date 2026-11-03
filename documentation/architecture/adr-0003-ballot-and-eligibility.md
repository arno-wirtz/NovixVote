# ADR-0003: Ballot builder, voter lists and eligibility

## Eligibility model (decided in this phase)
| Election access | Who is eligible | Discoverable? |
|---|---|---|
| **Restricted** | The person's **confirmed** email address is on the election's voter list. Workspace membership is neither required nor sufficient. | Listed on the dashboard of people on the list |
| **Public** | Any signed-in account with a confirmed email. | **Never listed.** Reachable only by the election link |

- Matching is by confirmed email (`auth.users.email_confirmed_at`), so a typed-in address can't be claimed by someone else. Keep Supabase email confirmation **enabled** in production.
- **Public elections cannot guarantee one person, one vote**: anyone can create several accounts. The UI says so. They suit polls and informal decisions, not binding votes. Binding votes should be restricted, with a list the organisation controls.
- Drafts are visible only to election managers. Scheduled and later elections are visible to workspace members and eligible voters; the voter list itself is visible to managers only.
- `is_eligible_voter(election)` is the single database function the voting phase will use to authorise casting a ballot.

## Ballot model
- `ballot_options` holds candidates (plurality) or lists (D'Hondt, Sainte-Laguë). A list's `members` are its ordered candidates: the first names receive the seats the list wins (closed lists). Candidate-based methods reject members.
- Up to 200 options per ballot; unique names (case-insensitive); order is explicit (`sort_order`) and changed with accessible up/down controls rather than drag and drop.
- The ballot, like the other election details, can only change while the election is a draft.

## Voter list
- Identity data: visible to election managers only and never joined to ballot data (ballots arrive in phase 5 under the separation described in the architecture documents).
- Imports are validated row by row in the database (invalid rows reported with their line number, duplicates skipped, at most 1,000 per request and 10,000 per election). Audit events record counts only, never addresses.
- Editable while draft or scheduled; locked once voting opens. A public election has no list, and a list can't coexist with switching an election to public (explicit error instead of silent deletion).

## Scheduling gate
`election_readiness()` is the one definition of "ready to schedule" (time window, future opening, at least 2 options, at least one voter if restricted). `transition_election()` enforces it and the UI shows it as a checklist, so the two can't drift apart.

## Deferred
Contested-seat rules (e.g. fewer candidates than seats), uncontested elections, voter-list import from integrations, and sending emails to voters.
