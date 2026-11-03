-- Minimal stand-ins for Supabase objects, ONLY for running tests on plain PostgreSQL. Never run on a Supabase project.
do $$ declare r text; begin foreach r in array array['anon','authenticated','service_role'] loop
  if not exists (select 1 from pg_roles where rolname = r) then execute format('create role %I nologin', r); end if; end loop; end $$;
create schema auth;
create table auth.users (id uuid primary key default gen_random_uuid(), email text, raw_user_meta_data jsonb,
                         email_confirmed_at timestamptz default now());
create function auth.uid() returns uuid language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claim.sub', true), ''),
                  (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'))::uuid $$;
grant usage on schema auth to authenticated; grant usage on schema public to anon, authenticated;
