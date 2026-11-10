import { useEffect, useRef, useState } from "react";
import { useAuth } from "../../app/providers/AuthProvider";
import { Alert, Button, Field } from "../../components/ui/ui";
import { ApiError } from "../../services/api";
import type { BallotOption, Election, MyVote, VotingMethod } from "../../types/api";
import "./castBallot.css";
import { rankingToSelection, selectionToRanks, validateSelection } from "./voteRules";

type Stage = "choose" | "review" | "done";

/** The interactive ballot for an eligible voter in an open election. The server re-validates everything. */
export function CastBallot({ election, options, method }: { election: Election; options: BallotOption[]; method: VotingMethod | undefined }) {
  const { api } = useAuth();
  const kind = method?.ballot_type ?? "candidate";
  const [status, setStatus] = useState<MyVote | null>(null);
  const [picked, setPicked] = useState<string[]>([]);
  const [ranks, setRanks] = useState<Record<string, string>>({});
  const [stage, setStage] = useState<Stage>("choose");
  const [editing, setEditing] = useState(false);
  const [receipt, setReceipt] = useState<{ token: string; changed: boolean } | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [problem, setProblem] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [copied, setCopied] = useState(false);
  const heading = useRef<HTMLHeadingElement>(null);

  useEffect(() => { api.myVote(election.id).then(setStatus).catch((e) => setError(e instanceof ApiError ? e.message : "Couldn't load your voting status")); }, [api, election.id]);
  useEffect(() => { heading.current?.focus(); }, [stage, editing]);

  const label = (id: string) => options.find((o) => o.id === id)?.label ?? "Unknown option";
  const ranking = kind === "ranked" ? rankingToSelection(ranks) : { selection: picked, error: null };
  const selection = ranking.selection;

  async function startChange() {
    setError(null); setProblem(null);
    try {
      const fresh = await api.myVote(election.id);   // the server returns the current selections to their owner while changes are allowed
      setStatus(fresh);
      const current = fresh.selections ?? [];
      if (kind === "ranked") setRanks(selectionToRanks(current)); else setPicked(current);
      setEditing(true); setStage("choose");
    } catch (e) { setError(e instanceof ApiError ? e.message : "Couldn't load your current vote"); }
  }
  function toReview() {
    const p = ranking.error ?? validateSelection(kind, election.seats, selection, election.allow_blank_ballot);
    setProblem(p);
    if (!p) setStage("review");
  }
  function toggle(id: string) {
    setProblem(null);
    setPicked((cur) => kind === "party_list" ? [id] : cur.includes(id) ? cur.filter((x) => x !== id) : [...cur, id]);
  }
  async function submit() {
    setBusy(true); setError(null);
    try {
      const r = await api.castVote(election.id, selection);
      setReceipt({ token: r.receipt, changed: r.changed });
      setStatus({ voted: true, can_change: election.allow_vote_change, selections: null });
      setPicked([]); setRanks({}); setEditing(false); setStage("done");   // drop the ballot from local state once it is recorded
    } catch (e) {
      setError(e instanceof ApiError ? e.message : "Couldn't record your vote. Check your connection, then check your voting status before trying again.");
      if (e instanceof ApiError && e.status === 409) api.myVote(election.id).then(setStatus).catch(() => undefined);
    } finally { setBusy(false); }
  }
  async function copy() {
    try { await navigator.clipboard.writeText(receipt?.token ?? ""); setCopied(true); } catch { setCopied(false); }
  }

  if (!status) return error ? <Alert tone="danger">{error}</Alert> : <p className="muted" role="status">Loading…</p>;

  if (stage === "done" && receipt) {
    return (
      <div className="cast-ballot">
        <Alert tone="success"><h3 ref={heading} tabIndex={-1}>{receipt.changed ? "Your vote has been changed" : "Your vote has been recorded"}</h3></Alert>
        {error && <Alert tone="danger">{error}</Alert>}
        <p>Keep this receipt. It lets you confirm later that your ballot was included. It does not show, and can't prove, what you chose.</p>
        <code className="receipt-box" aria-label="Your receipt">{receipt.token}</code>
        <div className="row-actions wrap">
          <Button variant="secondary" onClick={() => void copy()}>{copied ? "Copied" : "Copy receipt"}</Button>
          {election.allow_vote_change && <Button variant="secondary" onClick={() => void startChange()}>Change my vote</Button>}
        </div>
        <p className="muted small">{election.allow_vote_change ? "You can change your vote until voting closes. Your latest receipt replaces this one." : "Votes can't be changed in this election."}</p>
        <ReceiptCheck electionId={election.id} />
      </div>
    );
  }

  if (status.voted && !editing) {
    return (
      <div className="cast-ballot">
        <Alert tone="success"><h3 ref={heading} tabIndex={-1}>You have voted</h3></Alert>
        {error && <Alert tone="danger">{error}</Alert>}
        {status.can_change
          ? <><p>You can change your vote until voting closes.</p><Button onClick={() => void startChange()}>Change my vote</Button></>
          : <p className="muted">Votes can't be changed in this election.</p>}
        <ReceiptCheck electionId={election.id} />
      </div>
    );
  }

  const hint = kind === "party_list" ? "Choose one list." : kind === "ranked" ? "Rank as many candidates as you like, with 1 as your first choice."
    : `Choose up to ${election.seats} ${election.seats === 1 ? "candidate" : "candidates"}.`;
  const required = election.allow_blank_ballot ? "You may also submit a blank ballot." : "You must make at least one selection.";

  if (stage === "review") {
    return (
      <div className="cast-ballot">
        <h3 ref={heading} tabIndex={-1}>Review your vote</h3>
        {error && <Alert tone="danger">{error}</Alert>}
        {selection.length === 0 ? <p><strong>Blank ballot</strong>: no selection.</p> : (
          <ol className="review-list">{selection.map((id) => <li key={id}>{label(id)}</li>)}</ol>
        )}
        <p className="muted small">{election.allow_vote_change ? "You can change your vote after submitting, until voting closes." : "You can't change your vote after submitting."}</p>
        <div className="row-actions wrap">
          <Button variant="secondary" disabled={busy} onClick={() => setStage("choose")}>Back</Button>
          <Button loading={busy} onClick={() => void submit()}>{editing ? "Submit changed vote" : "Submit vote"}</Button>
        </div>
      </div>
    );
  }

  return (
    <div className="cast-ballot">
      <h3 ref={heading} tabIndex={-1}>{editing ? "Change your vote" : "Cast your vote"}</h3>
      <p className="small muted">{hint} {required}</p>
      {error && <Alert tone="danger">{error}</Alert>}
      {problem && <Alert tone="danger">{problem}</Alert>}
      <ul className="ballot-options">
        {options.map((o) => (
          <li key={o.id}>
            <label className="ballot-option">
              {kind === "ranked" ? (
                <select className="rank-select" aria-label={`Rank for ${o.label}`} value={ranks[o.id] ?? ""}
                  onChange={(e) => { setProblem(null); setRanks((r) => ({ ...r, [o.id]: e.target.value })); }}>
                  <option value="">Not ranked</option>
                  {options.map((_, i) => <option key={i + 1} value={String(i + 1)}>{i + 1}</option>)}
                </select>
              ) : (
                <input type={kind === "party_list" ? "radio" : "checkbox"} name="ballot" checked={picked.includes(o.id)} onChange={() => toggle(o.id)} aria-label={o.label} />
              )}
              <span><strong>{o.label}</strong>
                {o.description && <span className="muted small">{o.description}</span>}
                {o.members.length > 0 && <ol className="members small">{o.members.map((m) => <li key={m}>{m}</li>)}</ol>}
              </span>
            </label>
          </li>
        ))}
      </ul>
      <div className="row-actions wrap">
        {editing && <Button variant="secondary" onClick={() => { setEditing(false); setProblem(null); }}>Cancel</Button>}
        <Button onClick={toReview}>Review vote</Button>
      </div>
    </div>
  );
}

function ReceiptCheck({ electionId }: { electionId: string }) {
  const { api } = useAuth();
  const [value, setValue] = useState("");
  const [result, setResult] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  async function check() {
    setBusy(true); setResult(null);
    try {
      const r = await api.verifyReceipt(electionId, value.trim());
      setResult(r.included ? "This receipt matches a ballot that is included in the count." : "No counted ballot matches this receipt. If you changed your vote, only your latest receipt matches.");
    } catch (e) { setResult(e instanceof ApiError ? e.message : "Couldn't check the receipt"); } finally { setBusy(false); }
  }
  return (
    <div className="receipt-check">
      <div className="row-actions">
        <Field label="Check a receipt" value={value} onChange={(e) => setValue(e.target.value)} autoComplete="off" spellCheck={false} />
        <Button variant="secondary" loading={busy} disabled={value.trim().length === 0} onClick={() => void check()}>Check</Button>
      </div>
      {result && <p role="status" className="small">{result}</p>}
    </div>
  );
}
