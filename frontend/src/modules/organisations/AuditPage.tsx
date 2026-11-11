import { useCallback, useEffect, useState } from "react";
import { useAuth } from "../../app/providers/AuthProvider";
import { Alert, Button, Card, StatusBadge } from "../../components/ui/ui";
import { ApiError } from "../../services/api";
import type { AuditEvent, AuditVerify } from "../../types/api";
import { formatDateTime } from "../elections/lifecycle";
import "../elections/results.css";
import { useOrgContext } from "./useOrgContext";

const PAGE = 50;
const LABEL: Record<string, string> = {
  "organisation.created": "Workspace created", "invitation.created": "Invitation sent", "invitation.accepted": "Invitation accepted", "invitation.declined": "Invitation declined",
  "invitation.revoked": "Invitation revoked", "member.role_changed": "Role changed", "member.removed": "Member removed", "member.left": "Member left",
  "election.created": "Election created", "election.updated": "Election updated", "election.deleted": "Election deleted", "election.status_changed": "Election status changed",
  "ballot.option_added": "Ballot option added", "ballot.option_updated": "Ballot option updated", "ballot.option_removed": "Ballot option removed", "ballot.reordered": "Ballot reordered",
  "voters.added": "Voters added", "voters.removed": "Voter removed", "vote.accepted": "Ballot accepted", "tally.recorded": "Votes counted", "tally.approved": "Count approved",
};

/** Read-only trail of what happened in the workspace, with a check that the tamper-evident chain is intact. */
export function AuditPage() {
  const { orgId, can } = useOrgContext();
  const { api } = useAuth();
  const [events, setEvents] = useState<AuditEvent[] | null>(null);
  const [names, setNames] = useState<Record<string, string>>({});
  const [more, setMore] = useState(false);
  const [verify, setVerify] = useState<AuditVerify | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async (before?: number) => {
    try {
      const page = await api.auditEvents(orgId, { limit: PAGE, before });
      setEvents((cur) => (before ? [...(cur ?? []), ...page] : page)); setMore(page.length === PAGE);
    } catch (e) { setError(e instanceof ApiError ? e.message : "Couldn't load the audit trail"); }
  }, [api, orgId]);
  useEffect(() => {
    void load();
    api.members(orgId).then((m) => setNames(Object.fromEntries(m.map((x) => [x.user_id, x.display_name || x.email || "Member"])))).catch(() => undefined);
  }, [api, orgId, load]);

  if (!can("audit.read")) return <Alert tone="danger">You don't have permission to view the audit trail.</Alert>;
  async function check() {
    setBusy(true); setError(null);
    try { setVerify(await api.verifyAudit(orgId)); } catch (e) { setError(e instanceof ApiError ? e.message : "Couldn't verify the audit trail"); } finally { setBusy(false); }
  }
  return (
    <>
      {error && <Alert tone="danger">{error}</Alert>}
      <Card title="Integrity" action={<Button variant="secondary" loading={busy} onClick={() => void check()}>Verify audit trail</Button>}>
        <p className="muted small">Each event is chained to the one before it. Verification recomputes the whole chain and reports the first event that doesn't match. A chain kept only in this database can't prove it was never rewritten by someone who controls it; external anchoring is planned.</p>
        {verify && (verify.ok
          ? <StatusBadge tone="success">Chain intact: {verify.checked} events checked</StatusBadge>
          : <StatusBadge tone="danger">Chain broken at event {verify.first_bad_id} ({verify.checked} checked)</StatusBadge>)}
      </Card>
      <Card title="Activity">
        {!events && !error && <p className="muted" role="status">Loading…</p>}
        {events?.length === 0 && <p className="muted">Nothing has been recorded yet.</p>}
        <ul className="list">
          {events?.map((e) => (
            <li key={e.id}>
              <div>
                <strong>{LABEL[e.event_type] ?? e.event_type}</strong>
                <span className="muted small">{formatDateTime(e.created_at)} · {e.actor_id ? names[e.actor_id] ?? "Former member" : "System"}{e.entity_type ? ` · ${e.entity_type}` : ""}</span>
                {Object.keys(e.metadata).length > 0 && <details><summary className="small">Details</summary><pre className="audit-meta">{JSON.stringify(e.metadata, null, 1)}</pre></details>}
              </div>
              <span className="muted small mono">#{e.id}</span>
            </li>
          ))}
        </ul>
        {more && events && <div className="pager"><Button variant="secondary" onClick={() => void load(events[events.length - 1].id)}>Load older events</Button></div>}
      </Card>
    </>
  );
}
