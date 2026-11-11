import { useEffect, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { useAuth } from "../../app/providers/AuthProvider";
import { Alert, Button, Card, StatusBadge } from "../../components/ui/ui";
import { ApiError } from "../../services/api";
import type { ElectionStatus, ReadinessItem, Turnout } from "../../types/api";
import { useElectionContext } from "./ElectionLayout";
import { STATUS_HELP, STATUS_LABEL, STATUS_ORDER, availableActions, canEditOrDelete, formatDateTime, type LifecycleAction } from "./lifecycle";

const FIX_TAB: Record<string, string> = { ballot: "ballot", voters: "voters" };

export function ElectionOverviewPage() {
  const { orgId, election, setElection, method, membership, can } = useElectionContext();
  const { api } = useAuth();
  const navigate = useNavigate();
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [pending, setPending] = useState<string | null>(null); // key of the action/delete awaiting inline confirmation
  const [readiness, setReadiness] = useState<ReadinessItem[] | null>(null);
  const [turnout, setTurnout] = useState<Turnout | null>(null);

  const perms = membership.permissions;
  const showReadiness = election.status === "draft" && can("election.manage");
  useEffect(() => {
    if (showReadiness) api.readiness(election.id).then(setReadiness).catch(() => setReadiness(null));
  }, [api, election.id, election.updated_at, showReadiness]);
  const notReady = readiness?.some((r) => !r.ok) ?? false;

  // Aggregate turnout (counts only) for people who can view results; refreshed while voting is open.
  const showTurnout = can("results.view") && (election.status === "open" || election.status === "closed" || election.status === "published");
  useEffect(() => {
    if (!showTurnout) return;
    const load = () => api.turnout(election.id).then(setTurnout).catch(() => setTurnout(null));
    void load();
    if (election.status !== "open") return;
    const t = window.setInterval(() => void load(), 30_000);
    return () => window.clearInterval(t);
  }, [api, election.id, election.status, showTurnout]);

  async function transition(action: LifecycleAction) {
    setBusy(true); setError(null);
    try { setElection(await api.transitionElection(election.id, action.to)); setPending(null); }
    catch (e) { setError(e instanceof ApiError ? e.message : "Couldn't update the election"); }
    finally { setBusy(false); }
  }
  async function remove() {
    setBusy(true); setError(null);
    try { await api.deleteElection(election.id); navigate(`/workspaces/${orgId}/elections`); }
    catch (e) { setError(e instanceof ApiError ? e.message : "Couldn't delete the draft"); setBusy(false); }
  }

  const actions = availableActions(election.status, perms);
  const idx = STATUS_ORDER.indexOf(election.status);
  const pct = turnout?.eligible ? Math.round((turnout.voted / turnout.eligible) * 1000) / 10 : null;
  return (
    <>
      <Card>
        {election.description && <p>{election.description}</p>}
        <ol className="timeline" aria-label="Election lifecycle">
          {STATUS_ORDER.map((s: ElectionStatus, i) => (
            <li key={s} aria-current={i === idx ? "step" : undefined} className={i === idx ? "is-current" : i < idx ? "is-done" : ""}>
              <span className="step-num" aria-hidden="true">{i < idx ? "✓" : i + 1}</span>{STATUS_LABEL[s]}
            </li>
          ))}
        </ol>
        <p className="muted">{STATUS_HELP[election.status]}</p>
        {error && <Alert tone="danger">{error}</Alert>}

        {showReadiness && readiness && (
          <section aria-labelledby="ready-h" className="readiness">
            <h3 id="ready-h">Before you can schedule</h3>
            <ul className="checklist">
              {readiness.map((r) => (
                <li key={r.key} className={r.ok ? "is-ok" : "is-todo"}>
                  <span aria-hidden="true" className="check-icon">{r.ok ? "✓" : "!"}</span>
                  <span>{r.ok ? r.label : r.problem}{!r.ok && FIX_TAB[r.key] && <> · <Link to={FIX_TAB[r.key]}>Fix this</Link></>}</span>
                  <span className="sr-only">{r.ok ? "Done" : "To do"}</span>
                </li>
              ))}
            </ul>
          </section>
        )}

        <div className="row-actions wrap">
          {actions.map((a) => pending === a.to ? (
            <span key={a.to} className="row-actions wrap" role="group" aria-label={`Confirm: ${a.label}`}>
              <span className="small">{a.confirm}</span>
              <Button variant={a.tone === "danger" ? "danger" : "primary"} loading={busy} onClick={() => void transition(a)}>Yes, {a.label.toLowerCase()}</Button>
              <Button variant="secondary" onClick={() => setPending(null)}>Cancel</Button>
            </span>
          ) : (
            <Button key={a.to} variant={a.tone} disabled={busy || (a.to === "scheduled" && notReady)}
              onClick={() => (a.confirm ? setPending(a.to) : void transition(a))}>{a.label}</Button>
          ))}
          {canEditOrDelete(election, perms) && (
            <>
              <Link className="btn btn-secondary" to={`/workspaces/${orgId}/elections/${election.id}/edit`}>Edit details</Link>
              {pending === "delete" ? (
                <span className="row-actions wrap" role="group" aria-label="Confirm delete">
                  <span className="small">Delete this draft permanently?</span>
                  <Button variant="danger" loading={busy} onClick={() => void remove()}>Yes, delete</Button>
                  <Button variant="secondary" onClick={() => setPending(null)}>Cancel</Button>
                </span>
              ) : <Button variant="secondary" disabled={busy} onClick={() => setPending("delete")}>Delete draft</Button>}
            </>
          )}
        </div>
        {election.status === "closed" && perms.includes("results.approve") && (
          <p className="muted small">Count the votes and approve the count on the Results tab. An election with ballots can only be published after its count is approved.</p>
        )}
      </Card>

      {showTurnout && turnout && (
        <Card title="Turnout">
          <p className="metric">{turnout.voted}{turnout.eligible != null && <span className="muted small"> of {turnout.eligible} eligible voters{pct != null ? ` (${pct}%)` : ""}</span>}</p>
          <p className="muted small">{turnout.eligible != null ? "Voters who have cast a ballot" : "Accounts that have cast a ballot"}. Counts only: nobody can see who chose what.</p>
        </Card>
      )}

      <Card title="Details">
        <dl className="summary">
          <dt>Voting system</dt><dd>{method?.name ?? election.voting_method}</dd>
          <dt>Seats</dt><dd>{election.seats}</dd>
          {method?.supports_threshold && <><dt>Threshold</dt><dd>{election.threshold_percent ? `${election.threshold_percent}%` : "None"}</dd></>}
          <dt>Selection required</dt><dd>{election.allow_blank_ballot ? "No: blank ballots allowed" : "Yes: at least one choice"}</dd>
          <dt>Voters can change their vote</dt><dd>{election.allow_vote_change ? "Yes, until voting closes" : "No: final once submitted"}</dd>
          <dt>Who can vote</dt><dd>{election.access === "public" ? "Anyone with an account and the link" : "People on the voter list"}</dd>
          <dt>Opens</dt><dd>{formatDateTime(election.opens_at)}</dd>
          <dt>Closes</dt><dd>{formatDateTime(election.closes_at)}</dd>
          {election.published_at && <><dt>Published</dt><dd>{formatDateTime(election.published_at)}</dd></>}
        </dl>
        {election.access === "public" && <StatusBadge tone="info">Public elections can't verify one person per account</StatusBadge>}
      </Card>
    </>
  );
}
