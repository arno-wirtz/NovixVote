# Database and full-stack tests
Run on a **scratch PostgreSQL server only**. `supabase_stub.sql` creates stand-ins for Supabase roles and `auth.*`; never run it on a Supabase project.

## SQL tests (RLS, permissions, lifecycle, voting, audit)
```bash
PGURL=postgresql://postgres@localhost:5432/postgres ./run_local.sh
```
Applies the stub, migrations 0001-0007, then `rls_isolation.sql`, `rls_members_invitations.sql`, `rls_elections.sql`, `rls_ballot_voters.sql`, `rls_instant_runoff.sql` and `rls_voting.sql` in a throw-away database. Each file ends with a "passed" row; any failed assertion aborts with a clear message. `rls_elections.sql` includes real-time waits (about 5 s) to test automatic opening and closing. `rls_results.sql` covers counting permissions, hash-checked append-only counts, tie-break recording, the approval gate on publishing, voter-visible published results and audit-chain verification. `rls_voting.sql` covers the voting rules, duplicate and invalid votes, vote changes, receipts, key destruction at close and the absence of identity columns on `ballots`.

## Full-stack test (FastAPI -> PostgREST -> PostgreSQL)
1. Create a database, apply the stub and migrations, then:
   `create role authenticator noinherit login; grant anon, authenticated to authenticator;`
2. Run PostgREST with `db-uri` as `authenticator`, `db-schemas = "public"`, `db-anon-role = "anon"` and a `jwt-secret` of 32+ characters.
3. From `backend/`:
```bash
NV_IT_POSTGREST_URL=http://localhost:3000 NV_IT_JWT_SECRET=<same secret> \
NV_IT_PSQL_URL=postgresql://postgres@localhost/<db> pytest tests/integration
```
Without those variables the test is skipped.
