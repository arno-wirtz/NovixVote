# NovixVote — Voting made simple

Secure, configurable, multi-tenant voting platform. **Phases 1-4 are complete: foundation, members and election lifecycle, ballot builder with voter lists and eligibility, and four counting methods (plurality, D'Hondt, Sainte-Laguë, instant-runoff).**

| Layer | Tech | Folder |
|---|---|---|
| UI | React 18, TypeScript, Vite | `frontend/` |
| API | Python 3.11+, FastAPI | `backend/` |
| Data + auth | Supabase (PostgreSQL, Auth, RLS) | `database/` |
| Docs | ADRs and plan | `documentation/` |

## What works
- Sign up / sign in (Supabase Auth), protected routes, responsive shell, dashboard, workspaces (create + list with your role).
- Light / dark / system theme, applied before first paint, persisted.
- FastAPI with JWT verification (HS256 or asymmetric/JWKS), `/api/v1/health`, `/auth/me`, `/organisations`, `/voting-methods`.
- Database: profiles, organisations, memberships, roles, permissions, tamper-evident audit chain, strict RLS.
- Framework-free voting-engine contract and registry with three methods: plurality, **D'Hondt** and **Sainte-Laguë** (exact integer arithmetic, optional electoral threshold, ties reported rather than broken silently, per-seat allocation log).
- **Members:** invitations (matched to the invitee's verified email, 14-day expiry, revocable), role changes, removal, leaving. Admins can't touch owners or grant admin; the last owner can't leave. Every change is audited.
- **Elections:** draft → scheduled → open → closed → published, enforced in the database. Creation wizard (4 steps, also used to edit drafts), detail page with lifecycle actions, automatic open/close at the scheduled times, drafts hidden from voters, publishing restricted to people with results-approval rights.

- **Ballot builder:** candidates (plurality) or ordered lists with their candidates (D'Hondt/Sainte-Laguë), reorder, edit, remove, live "voter's view" preview. Locked once the election leaves draft.
- **Voter lists:** paste or upload CSV (`email` or `email,name`, header optional, quoted names, comma/semicolon/tab), per-row error reporting, duplicates skipped, search and paging, up to 10,000 voters. Locked when voting opens.
- **Eligibility:** *restricted* = confirmed email on the voter list (workspace membership not required); *public* = any signed-in account with a confirmed email, reachable by link only and never listed. Eligible voters get a read-only election page and a dashboard card.
- **Scheduling gate:** an election can only be scheduled when it has a time window in the future, at least 2 candidates/lists and (if restricted) at least one voter. The same readiness check drives the checklist in the UI.

- **Instant-runoff (majority/runoff, one winner):** ranked ballots, exact round-by-round elimination log, zero-vote bulk elimination, previous-round tie rule, and a recorded tie-break order for ties that remain. Elects exactly one seat (a per-method `max_seats` rule enforced in the database, API and wizard).

Not built yet (deliberately): casting votes, counting wired to elections (needs stored ballots), two-round runoff, results display, notifications (invitations are shown in-app after sign-in; no emails are sent). **Open elections cannot be voted in yet**; that is phase 5. See `documentation/architecture/implementation-plan.md`.

## Run locally
Prerequisites: Node 20+, Python 3.11+, a Supabase project (or `supabase start` locally).

1. **Database** — apply `database/migrations/0001_…`, `0002_…`, `0003_…` in order (SQL editor, `psql`, or copy to `supabase/migrations/` and `supabase db push`).
2. **Backend**
   ```bash
   cd backend && python -m venv .venv && source .venv/bin/activate
   pip install -r requirements-dev.txt
   cp .env.example .env   # fill SUPABASE_URL, SUPABASE_ANON_KEY (+ SUPABASE_JWT_SECRET only if your project uses the legacy HS256 secret)
   uvicorn app.main:app --reload --port 8000
   ```
3. **Frontend**
   ```bash
   cd frontend && npm install
   cp .env.example .env.local   # VITE_SUPABASE_URL, VITE_SUPABASE_ANON_KEY
   npm run dev                  # http://localhost:5173 (proxies /api to :8000)
   ```
   For quick local testing, disable "Confirm email" in Supabase Auth settings.

## Tests
```bash
cd backend && pytest                      # API, auth, config, voting engine (plurality, D'Hondt, Sainte-Laguë, instant-runoff, registry/database consistency)
cd frontend && npm test && npm run build  # unit tests, typecheck, production build
# Database + full-stack tests need a scratch PostgreSQL (and PostgREST for the last one): see database/tests/README.md
```

## Security rules in force
- No service-role key anywhere in this phase. The backend forwards the user's JWT to Supabase, so RLS always applies.
- Workspaces can only be created through `create_organisation()` (atomic: org + owner + audit event).
- Membership, invitation and election writes only happen through audited SECURITY DEFINER functions; API roles have no direct write access to those tables.
- Admins cannot create or modify owners; the last owner can never leave or be demoted.
- `audit_events` is append-only (triggers) and hash-chained per workspace. A hash chain alone is not tamper-proof; signed checkpoints and external anchoring are planned.
- Secrets live only in `.env` files (git-ignored). Examples contain no real values.

## Production notes
- Elections open and close when `advance_elections()` runs. The API calls it on every election read and transition, so state is always correct when viewed; for timely audit events with nobody looking, schedule it every minute with `pg_cron` (command in `0003_elections.sql`).
- Invitations rely on Supabase email confirmation being **enabled** in production, so only the real owner of an address can claim its invitations.
