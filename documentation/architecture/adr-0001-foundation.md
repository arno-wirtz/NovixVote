# ADR-0001: Foundation decisions
1. **One platform, two deployment profiles** (organisational first; public-sector later) — per the architecture documents.
2. **Backend forwards the user's JWT to PostgREST** instead of holding a service-role key. RLS is the primary tenant boundary; FastAPI adds validation, orchestration and the voting engine. A privileged key will be introduced only for specific server-side jobs (e.g. ballot issuance) in a later ADR.
3. **JWT verification** accepts HS256 (legacy secret) and ES256/RS256 via JWKS from an allow-list; `alg=none` is rejected.
4. **Workspace creation via a SECURITY DEFINER RPC** so organisation, owner membership and audit event are one transaction; no direct INSERT policy exists on `organisations`.
5. **Helper functions bypass RLS deliberately** (`is_org_member`, `has_permission`, …) to avoid policy recursion; each has a pinned `search_path` and answers only about `auth.uid()`.
6. **Voting engine is a pure-Python package** (`backend/app/domain/voting_methods`) with a `VotingMethod` protocol and registry. It imports nothing from FastAPI, the database or the UI. Ties are reported, never silently broken.
7. **Audit trail**: per-workspace SHA-256 hash chain, advisory-lock serialised, append-only triggers. Metadata must never contain ballot selections or secrets.
8. **Ballot secrecy (future)**: voter identity, voting authorisation and ballot content live in separate domains with an unlinkable authorisation step (blind-token/credential approach, to be reviewed independently). Nothing in phase 1 stores ballots.
9. **Design system**: the supplied tokens (blue/green/red-orange only, Manrope + Inter self-hosted via Fontsource, no purple) are used verbatim as semantic CSS variables; components never hard-code colours.
