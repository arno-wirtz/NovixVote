# Implementation plan
| Phase | Scope | Exit criteria |
|---|---|---|
| 1 ✅ Foundation | Repo, design system, themes, auth, workspaces, RLS, audit chain, plurality engine, health check | Tests green; migration verified on Postgres |
| 2 ✅ Members & elections | Invitations, role management, election model + lifecycle, creation wizard, D'Hondt and Sainte-Laguë engines | SQL, API, full-stack and unit tests green |
| 3 ✅ Ballot builder | Candidates and lists, voter lists (CSV import), restricted vs public eligibility, ballot-ready gate on scheduling | SQL, API, full-stack and unit tests green |
| 4 ✅ Voting engine | Instant-runoff (majority/runoff, one winner) with round log and tie handling | Deterministic, documented algorithms; property tests |
| 5 Secure voting | Unlinkable authorisation, idempotent submission, duplicate prevention, QR inclusion receipt that cannot prove a choice | Independent security review |
| 6 Results & audit | Wire counting to stored ballots, tie-break recording, approval flow, exports, audit viewer, signed checkpoints; optional: two-round runoff, largest remainder, STV | Reproducible counts |
| 7 Notifications & admin | Email notifications, platform administration | |
| 8 Staging & release | E2E tests, backup/restore drill, load test, accessibility audit, production release | Sign-off |

Open decisions for you: majority/runoff rules (two-round vs instant-runoff), ballot-less tie-break procedure wording, email provider, hosting targets.
