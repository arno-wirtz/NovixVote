# Database and full-stack tests
Run on a **scratch PostgreSQL server only**. `supabase_stub.sql` creates stand-ins for Supabase roles and `auth.*`; never run it on a Supabase project.

## SQL tests (RLS, permissions, lifecycle, audit)
```bash
PGURL=postgresql://postgres@localhost:5432/postgres ./run_local.sh
```
Applies the stub, all migrations, then `rls_isolation.sql`, `rls_members_invitations.sql`, `rls_elections.sql` in a throw-away database. Each file ends with a "passed" row; any failed assertion aborts with a clear message. `rls_elections.sql` includes real-time waits (about 5 s) to test automatic opening and closing.

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
