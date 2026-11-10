# NovixVote — Voting made simple

Secure, configurable, multi-tenant voting platform. **Phases 1-5 are complete: foundation, members and election lifecycle, ballot builder with voter lists and eligibility, four counting methods (plurality, D'Hondt, Sainte-Laguë, instant-runoff), and secure voting.**

| Layer | Tech | Folder |
|---|---|---|
| UI | React 18, TypeScript, Vite | `frontend/` |
| API | Python 3.11+, FastAPI | `backend/` |
| Data + auth | Supabase (PostgreSQL, Auth, RLS) | `database/` |
| Docs | ADRs and plan | `documentation/` |

## What works
- Sign up / sign in (Supabase Auth), protected routes, responsive shell, dashboard, workspaces, light / dark / system theme.
- FastAPI with JWT verification, `/api/v1/health`, `/auth/me`, `/organisations`, `/voting-methods`.
- Database: profiles, organisations, memberships, roles, permissions, tamper-evident audit chain, strict RLS.
- Framework-free voting engine with plurality, D'Hondt, Sainte-Laguë and instant-runoff (exact integer arithmetic, ties reported not broken silently).
- Members and invitations; election lifecycle draft → scheduled → open → closed → published, enforced in the database.
- Ballot builder, voter lists (CSV), restricted vs public eligibility, scheduling gate.
- **Voting (phase 5):** eligible voters cast a ballot on an open election (single choice, multi-choice up to the seats, one list, or ranked). The person in charge sets two rules in the wizard, both frozen once the election leaves draft:
  - *Voters must make a selection* (default on). Turn off to allow blank ballots.
  - *Voters can change their vote while voting is open* (default on). Turn off for one final vote.
  Voters get a receipt that proves inclusion without revealing their choice, can check it, and (when allowed) can review and change their vote until voting closes. Managers see aggregate turnout only. See `documentation/architecture/adr-0005-secure-voting.md` for the secrecy trade-off of vote changes.

Not built yet (deliberately): counting wired to stored ballots, tie-break recording, results display and approval (phase 6), ballot encryption at rest, rate limiting, notifications/emails, two-round runoff.

## Run locally
Prerequisites: Node 20+, Python 3.11+, a Supabase project (or `supabase start` locally).

1. **Database** — apply `database/migrations/0001_…` to `0006_…` in order (SQL editor, `psql`, or copy to `supabase/migrations/` and `supabase db push`).
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
cd backend && pytest                      # API, auth, config, voting engine, voting API
cd frontend && npm test && npm run build  # unit tests, typecheck, production build
# Database + full-stack tests need a scratch PostgreSQL (and PostgREST for the last one): see database/tests/README.md
```

## Security rules in force
- No service-role key anywhere. The backend forwards the user's JWT to Supabase, so RLS always applies.
- Workspaces only via `create_organisation()`; membership, invitation, election and voting writes only through audited SECURITY DEFINER functions.
- `vote_participation`, `ballots` and `election_vote_keys` have no grants or policies for API roles. Ballots carry no user, email, session or timestamp columns; audit events for votes carry no actor and no selections.
- Admins cannot create or modify owners; the last owner can never leave or be demoted.
- `audit_events` is append-only and hash-chained per workspace. A hash chain alone is not tamper-proof; signed checkpoints and external anchoring are planned.
- Secrets live only in `.env` files (git-ignored).

## Production notes
- Elections open and close when `advance_elections()` runs. The API calls it on every election read, vote and transition; for timely audit events with nobody looking, schedule it every minute with `pg_cron` (command in `0003_elections.sql`).
- Invitations and eligibility rely on Supabase email confirmation being **enabled** in production.
- Binding elections need the independent security review described in ADR-0005 first.
