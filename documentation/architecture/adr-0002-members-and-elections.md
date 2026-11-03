# ADR-0002: Members, invitations, election lifecycle, proportional counting

## Membership and invitations
1. All membership writes go through audited SECURITY DEFINER functions (`create_invitation`, `respond_to_invitation`, `change_member_role`, `remove_member`); direct INSERT/UPDATE/DELETE grants were revoked.
2. **Invitations are matched to the invitee's confirmed email** (`auth.users.email_confirmed_at`), never to client input. No token is mailed, so there is nothing to leak; the invitee sees it after signing in. Unknown and not-yours invitations return the same error. Email sending joins the notifications phase.
3. Role rules live in one function, `can_manage_role`: owners manage anyone; admins only election managers and voters; nobody else. The last owner can never be demoted, removed or leave (checked under a row lock). The UI mirrors these rules for convenience; the database is the authority.
4. Audit metadata never contains email addresses.

## Application errors
Our functions raise custom SQLSTATEs `NV403/404/409/422`. The API maps them to HTTP codes and shows their (author-controlled) messages; every other database error becomes a generic 502 so internals never leak.

## Election lifecycle
`draft → scheduled → open → closed → published`. Allowed manual moves: schedule, unschedule (before opening), open now, close now, publish. Opening and closing at the scheduled times is done by `advance_elections()` (idempotent, run on reads and optionally by pg_cron).
- Only drafts can be edited or deleted. Scheduling requires opening and closing times with opening in the future.
- Publishing requires the `results.approve` permission (owners), separating running an election from approving it.
- Drafts are visible only to people with `election.manage`.
- **Known gap:** scheduling does not yet check that a ballot exists (phase 3 adds lists/candidates and that gate inside `transition_election`).

## Highest-averages proportional methods
- One vote for one list. After a list has won `s` seats its quotient is votes ÷ divisor(s): D'Hondt divisors 1, 2, 3, ...; Sainte-Laguë (pure, not the 1.4-modified variant) 1, 3, 5, ...
- Quotients are exact fractions: no floating point, no rounding.
- Electoral threshold: a list qualifies if votes × 100 ≥ threshold% × valid votes (blank and invalid ballots excluded; boundary inclusive).
- **Ties are never broken arbitrarily.** If lists tie for the next seat and there are enough seats for all, all receive one. Otherwise the tied lists are returned in `tied_for_last_seat` and the unfilled seats in `unallocated_seats`, so the election's documented tie-break (e.g. drawing lots, recorded in the audit log) is applied explicitly.
- Every seat is recorded in `allocation_log` (list, votes, divisor, quotient) so a count can be reproduced by hand.
- A new method needs: a class registered in `voting_methods/__init__.py` and a row in `public.voting_methods`.
