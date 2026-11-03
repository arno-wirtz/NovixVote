#!/usr/bin/env bash
# Usage: PGURL=postgresql://postgres@localhost:5432/postgres ./run_local.sh   (uses a throw-away database)
set -euo pipefail
cd "$(dirname "$0")"
PGURL="${PGURL:?set PGURL to a superuser connection string for a scratch server}"
DB="novixvote_test_$$"
psql "$PGURL" -qc "create database $DB"
trap 'psql "$PGURL" -qc "drop database $DB" || true' EXIT
URL="${PGURL%/*}/$DB"
for f in supabase_stub.sql ../migrations/0001_foundation.sql ../migrations/0002_members_invitations.sql ../migrations/0003_elections.sql ../migrations/0004_ballot_voters.sql ../migrations/0005_instant_runoff.sql \
         rls_isolation.sql rls_members_invitations.sql rls_elections.sql rls_ballot_voters.sql rls_instant_runoff.sql; do
  echo "== $f"; psql "$URL" -v ON_ERROR_STOP=1 -q -f "$f"
done
