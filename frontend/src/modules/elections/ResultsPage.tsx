import { useCallback, useEffect, useState } from "react";
import { useAuth } from "../../app/providers/AuthProvider";
import { Alert, Button, Card, SelectField, StatusBadge, TextAreaField } from "../../components/ui/ui";
import { ApiError } from "../../services/api";
import type { TallyRun, TieBreakInput } from "../../types/api";
import { useElectionContext } from "./ElectionLayout";
import { ResultView } from "./ResultView";
import { TIE_METHOD_LABEL } from "./resultRows";
import { formatDateTime } from "./lifecycle";
import "./results.css";

/** Counting, tie-break recording and approval. Every count is kept; a recount is a new run, never an edit. */
export function ResultsPage() {
  const { election, can } = useElectionContext();
  const { api } = useAuth();
  const [runs, setRuns] = useState<TallyRun[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [confirmApprove, setConfirmApprove] = useState(false);
  const [method, setMethod] = useState<TieBreakInput["method"]>("lots");
  const [note, setNote] = useState("");
  const [ranks, setRanks] = useState<Record<string, string>>({});

  const load = useCallback(() => api.tallyRuns(election.id).then(setRuns).catch((e) => setError(e instanceof ApiError ? e.message : "Couldn't load the counts")), [api, election.id]);
  useEffect(() => { void load(); }, [load]);

  const counted = election.status === "closed" || election.status === "published";
  const latest = runs?.[0] ?? null;
  const approved = runs?.find((r) => r.approved) ?? null;
  const tied = latest && !latest.result.complete ? latest.result.tied_for_last_seat : [];

  async function run(tieBreak?: TieBreakInput) {
    setBusy(true); setError(null);
    try { await api.runTally(election.id, tieBreak); setRanks({}); setNote(""); await load(); }
    catch (e) { setError(e instanceof ApiError ? e.message : "Couldn't count the votes"); } finally { setBusy(false); }
  }
  async function approve(r: TallyRun) {
    setBusy(true); setError(null);
    try { await api.approveRun(r.id); setConfirmApprove(false); await load(); }
    catch (e) { setError(e instanceof ApiError ? e.message : "Couldn't approve the count"); } finally { setBusy(false); }
  }
  function submitTieBreak() {
    const order = [...tied].sort((a, b) => Number(ranks[a]) - Number(ranks[b]));
    const used = tied.map((t) => ranks[t]);
    if (used.some((u) => !u) || new Set(used).size !== used.length) { setError("Give every tied candidate a different place in the order."); return; }
    if (note.trim().length < 3) { setError("Describe how the tie was broken, for example who drew lots and how."); return; }
    void run({ method, note: note.trim(), order });
  }

  if (!counted) return <Alert tone="info">Votes can be counted once voting has closed.</Alert>;
  if (!runs) return error ? <Alert tone="danger">{error}</Alert> : <p className="muted" role="status">Loading…</p>;

  return (
    <>
      {error && <Alert tone="danger">{error}</Alert>}
      <Card title="Count">
        {runs.length === 0 && <p className="muted">The ballots haven't been counted yet. Counting uses the election's voting method on the ballots as they stand now; the same count can be repeated by anyone with the same ballots.</p>}
        {election.status === "closed" && can("election.manage") && runs.length === 0 && <Button loading={busy} onClick={() => void run()}>Count the votes</Button>}
        {latest && (
          <>
            <p className="small muted">Count {latest.run_number} · {formatDateTime(latest.created_at)} · {latest.ballot_count} ballots{" "}
              {latest.approved ? <StatusBadge tone="success">Approved {latest.approved_at ? formatDateTime(latest.approved_at) : ""}</StatusBadge> : <StatusBadge tone="neutral">Not approved</StatusBadge>}</p>
            <ResultView result={latest.result} tieBreak={latest.tie_break} />
            <p className="small muted">Ballot-set fingerprint: <span className="mono">{latest.input_hash.slice(0, 16)}…</span></p>
          </>
        )}

        {election.status === "closed" && can("election.manage") && tied.length > 0 && (
          <section className="tie-form" aria-labelledby="tie-h">
            <h3 id="tie-h">Record how the tie was broken</h3>
            <p className="muted small">Votes alone don't decide this. Use your election's documented tie-break procedure, then record the outcome. Everything you enter is stored with the count and shown with the result.</p>
            <SelectField label="Procedure" value={method} onChange={(e) => setMethod(e.target.value as TieBreakInput["method"])}>
              {Object.entries(TIE_METHOD_LABEL).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
            </SelectField>
            <fieldset className="choice-group"><legend>Order of the tied candidates, 1 = most favoured</legend>
              {tied.map((t) => (
                <SelectField key={t} label={t} value={ranks[t] ?? ""} onChange={(e) => setRanks((r) => ({ ...r, [t]: e.target.value }))}>
                  <option value="">Choose a place</option>{tied.map((_, i) => <option key={i} value={String(i + 1)}>{i + 1}</option>)}
                </SelectField>
              ))}
            </fieldset>
            <TextAreaField label="What was done" value={note} onChange={(e) => setNote(e.target.value)} maxLength={500} rows={3} hint="For example: lots drawn by the returning officer on 5 November, witnessed by two members." />
            <Button loading={busy} onClick={submitTieBreak}>Record tie-break and count again</Button>
          </section>
        )}

        {election.status === "closed" && latest && latest.result.complete && !latest.approved && (
          <div className="row-actions wrap">
            {can("election.manage") && <Button variant="secondary" loading={busy} onClick={() => void run(latest.tie_break ?? undefined)}>Count again</Button>}
            {can("results.approve") && (confirmApprove ? (
              <span className="row-actions wrap" role="group" aria-label="Confirm approval">
                <span className="small">Approve this count? It can't be undone, and the result can then be published.</span>
                <Button loading={busy} onClick={() => void approve(latest)}>Yes, approve</Button>
                <Button variant="secondary" onClick={() => setConfirmApprove(false)}>Cancel</Button>
              </span>
            ) : <Button onClick={() => setConfirmApprove(true)}>Approve this count</Button>)}
          </div>
        )}
        {election.status === "closed" && approved && <p className="muted small">Approved. Publish the result from the Overview tab.</p>}
        {election.status === "closed" && latest?.result.complete && !latest.approved && !can("results.approve") && <p className="muted small">Only people who can approve results may approve this count.</p>}
      </Card>

      {runs.length > 1 && (
        <Card title="Earlier counts">
          <ul className="list">{runs.slice(1).map((r) => (
            <li key={r.id}><div><strong>Count {r.run_number}</strong><span className="muted small">{formatDateTime(r.created_at)} · {r.result.complete ? `Elected: ${r.result.winners.join(", ") || "none"}` : `Unresolved tie: ${r.result.tied_for_last_seat.join(", ")}`}</span></div></li>
          ))}</ul>
        </Card>
      )}
    </>
  );
}
