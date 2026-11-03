import { useCallback, useEffect, useState } from "react";
import { useAuth } from "../../app/providers/AuthProvider";
import { Alert, Button, Card, Field, TextAreaField } from "../../components/ui/ui";
import { ApiError } from "../../services/api";
import type { VoterPage, VotersResult } from "../../types/api";
import { useElectionContext } from "./ElectionLayout";
import { chunk, parseVoterText, type ParsedVoters } from "./voterCsv";

const PAGE = 50;
const MAX_FILE_BYTES = 2_000_000;

export function VotersPage() {
  const { election } = useElectionContext();
  const { api } = useAuth();
  const locked = election.status !== "draft" && election.status !== "scheduled";
  const [page, setPage] = useState<VoterPage | null>(null);
  const [offset, setOffset] = useState(0);
  const [search, setSearch] = useState("");
  const [query, setQuery] = useState("");
  const [text, setText] = useState("");
  const [parsed, setParsed] = useState<ParsedVoters | null>(null);
  const [result, setResult] = useState<VotersResult | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [removing, setRemoving] = useState<string | null>(null);

  useEffect(() => { const t = window.setTimeout(() => { setQuery(search.trim()); setOffset(0); }, 300); return () => window.clearTimeout(t); }, [search]);
  const load = useCallback(() => api.voters(election.id, { limit: PAGE, offset, search: query || undefined }).then(setPage)
    .catch((e) => setError(e instanceof ApiError ? e.message : "Couldn't load the voter list")), [api, election.id, offset, query]);
  useEffect(() => { void load(); }, [load]);

  if (election.access !== "restricted") return <Alert tone="info">Public elections don't use a voter list. Anyone with an account and the election link can vote.</Alert>;

  function onText(value: string) { setText(value); setResult(null); setParsed(value.trim() ? parseVoterText(value) : null); }
  async function onFile(file: File | undefined) {
    if (!file) return;
    if (file.size > MAX_FILE_BYTES) { setError("That file is larger than 2 MB. Split it into smaller files."); return; }
    setError(null); onText(await file.text());
  }
  async function submit() {
    if (!parsed || parsed.rows.length === 0) return;
    setBusy(true); setError(null);
    const total: VotersResult = { added: 0, duplicates: parsed.duplicates, invalid_count: 0, invalid: [], total: 0 };
    try {
      for (const part of chunk(parsed.rows, 1000)) {
        const r = await api.addVoters(election.id, part);
        total.added += r.added; total.duplicates += r.duplicates; total.invalid_count += r.invalid_count; total.total = r.total;
        total.invalid.push(...r.invalid);
      }
      setResult(total); setText(""); setParsed(null); setOffset(0); await load();
    } catch (e) {
      setError(e instanceof ApiError ? e.message : "Couldn't add voters");
      if (total.added > 0) { setResult(total); await load(); }
    } finally { setBusy(false); }
  }
  async function remove(id: string) {
    setBusy(true); setError(null);
    try { await api.removeVoter(id); setRemoving(null); await load(); }
    catch (e) { setError(e instanceof ApiError ? e.message : "Couldn't remove the voter"); } finally { setBusy(false); }
  }

  const shownTo = page ? Math.min(offset + PAGE, page.total) : 0;
  return (
    <div className="grid-2 grid-top">
      <Card title={`Voter list${page ? ` (${page.all_total})` : ""}`}>
        {error && <Alert tone="danger">{error}</Alert>}
        {locked && <Alert tone="info">The voter list is locked now that voting has opened.</Alert>}
        <Field label="Search voters" type="search" value={search} onChange={(e) => setSearch(e.target.value)} autoComplete="off" />
        {!page && !error && <p className="muted" role="status">Loading…</p>}
        {page?.all_total === 0 && <p className="muted">No voters yet. Only people on this list can vote, matched by their confirmed email address.</p>}
        {page && page.all_total > 0 && page.total === 0 && <p className="muted">No voters match your search.</p>}
        <ul className="list">
          {page?.items.map((v) => (
            <li key={v.id}>
              <div><strong>{v.name || v.email}</strong>{v.name && <span className="muted small">{v.email}</span>}</div>
              {!locked && (removing === v.id ? (
                <span className="row-actions wrap">
                  <Button variant="danger" loading={busy} onClick={() => void remove(v.id)}>Remove</Button>
                  <Button variant="secondary" onClick={() => setRemoving(null)}>Cancel</Button>
                </span>
              ) : <Button variant="secondary" disabled={busy} aria-label={`Remove ${v.email}`} onClick={() => setRemoving(v.id)}>Remove</Button>)}
            </li>
          ))}
        </ul>
        {page && page.total > PAGE && (
          <div className="pager">
            <Button variant="secondary" disabled={offset === 0} onClick={() => setOffset(Math.max(0, offset - PAGE))}>Previous</Button>
            <span className="small muted" role="status">{offset + 1}–{shownTo} of {page.total}</span>
            <Button variant="secondary" disabled={shownTo >= page.total} onClick={() => setOffset(offset + PAGE)}>Next</Button>
          </div>
        )}
      </Card>

      {!locked && (
        <Card title="Add voters">
          <p className="muted small">Paste one voter per line (<span className="mono">email</span> or <span className="mono">email, name</span>) or upload a CSV file. Existing voters are skipped.</p>
          <div className="field">
            <label htmlFor="voter-file">CSV file</label>
            <input id="voter-file" type="file" accept=".csv,.txt,text/csv,text/plain" onChange={(e) => { void onFile(e.target.files?.[0]); e.target.value = ""; }} />
          </div>
          <TextAreaField label="Or paste voters" rows={6} value={text} onChange={(e) => onText(e.target.value)} placeholder={"ana@example.com, Ana Diaz\nben@example.com"} />
          {parsed && (
            <div aria-live="polite">
              <p><strong>{parsed.rows.length}</strong> {parsed.rows.length === 1 ? "voter" : "voters"} ready to add{parsed.duplicates > 0 && <>, {parsed.duplicates} repeated in your list</>}{parsed.problems.length > 0 && <>, <strong>{parsed.problems.length}</strong> with problems</>}.</p>
              {parsed.problems.length > 0 && (
                <Alert tone="danger">
                  <p>These rows will be skipped:</p>
                  <ul className="problems">{parsed.problems.slice(0, 5).map((p) => <li key={p.line}>Line {p.line}: {p.value || "(empty)"} — {p.reason}</li>)}</ul>
                  {parsed.problems.length > 5 && <p className="small">…and {parsed.problems.length - 5} more.</p>}
                </Alert>
              )}
            </div>
          )}
          <Button loading={busy} disabled={!parsed || parsed.rows.length === 0} onClick={() => void submit()}>{parsed?.rows.length ? `Add ${parsed.rows.length} ${parsed.rows.length === 1 ? "voter" : "voters"}` : "Add voters"}</Button>
          {result && (
            <Alert tone={result.invalid_count > 0 ? "info" : "success"}>
              Added {result.added}. {result.duplicates > 0 && `${result.duplicates} already on the list. `}{result.invalid_count > 0 && `${result.invalid_count} rejected by the server.`}
            </Alert>
          )}
        </Card>
      )}
    </div>
  );
}
