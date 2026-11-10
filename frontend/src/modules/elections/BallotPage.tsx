import { useCallback, useEffect, useState, type FormEvent } from "react";
import { useAuth } from "../../app/providers/AuthProvider";
import { Alert, Button, Card, Field, TextAreaField } from "../../components/ui/ui";
import { ApiError } from "../../services/api";
import type { BallotOption } from "../../types/api";
import { BallotPreview } from "./BallotPreview";
import { moveItem, parseMembers, validateOption } from "./ballot";
import { useElectionContext } from "./ElectionLayout";

export function BallotPage() {
  const { election, method, can } = useElectionContext();
  const { api } = useAuth();
  const listBased = method?.ballot_type === "party_list";
  const noun = listBased ? "list" : "candidate";
  const editable = election.status === "draft" && can("election.manage");
  const [options, setOptions] = useState<BallotOption[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [editing, setEditing] = useState<string | null>(null);   // option id being edited
  const [label, setLabel] = useState("");
  const [description, setDescription] = useState("");
  const [membersText, setMembersText] = useState("");
  const [errors, setErrors] = useState<{ label?: string; description?: string; members?: string }>({});
  const [removing, setRemoving] = useState<string | null>(null);

  const load = useCallback(() => api.ballot(election.id).then(setOptions).catch(() => setError("Couldn't load the ballot")), [api, election.id]);
  useEffect(() => { void load(); }, [load]);

  const fail = (e: unknown, fallback: string) => setError(e instanceof ApiError ? e.message : fallback);
  function resetForm() { setEditing(null); setLabel(""); setDescription(""); setMembersText(""); setErrors({}); }

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    const members = listBased ? parseMembers(membersText) : [];
    const errs = validateOption(label, description, members, listBased);
    setErrors(errs);
    if (Object.keys(errs).length) return;
    setBusy(true); setError(null);
    try {
      const input = { label: label.trim(), description: description.trim() || null, members };
      await (editing ? api.updateOption(editing, input) : api.addOption(election.id, input));
      resetForm(); await load();
    } catch (err) { fail(err, "Couldn't save"); } finally { setBusy(false); }
  }
  async function move(index: number, delta: -1 | 1) {
    if (!options) return;
    setBusy(true); setError(null);
    try { await api.reorderOptions(election.id, moveItem(options.map((o) => o.id), index, delta)); await load(); }
    catch (err) { fail(err, "Couldn't reorder"); } finally { setBusy(false); }
  }
  async function remove(id: string) {
    setBusy(true); setError(null);
    try { await api.deleteOption(id); setRemoving(null); if (editing === id) resetForm(); await load(); }
    catch (err) { fail(err, "Couldn't remove"); } finally { setBusy(false); }
  }
  function startEdit(o: BallotOption) { setEditing(o.id); setLabel(o.label); setDescription(o.description ?? ""); setMembersText(o.members.join("\n")); setErrors({}); }

  return (
    <div className="grid-2 grid-top">
      <div>
        <Card title={listBased ? "Lists on the ballot" : "Candidates on the ballot"}>
          {error && <Alert tone="danger">{error}</Alert>}
          {!editable && <Alert tone="info">{can("election.manage") ? "The ballot is locked. Move the election back to draft to change it." : "This is the ballot as voters will see it."}</Alert>}
          {!options && !error && <p className="muted" role="status">Loading…</p>}
          {options?.length === 0 && <p className="muted">Nothing here yet. {editable ? `Add at least 2 ${noun}s to be able to schedule.` : ""}</p>}
          <ol className="option-list">
            {options?.map((o, i) => (
              <li key={o.id}>
                <div className="option-main"><strong>{o.label}</strong>
                  {o.description && <span className="muted small">{o.description}</span>}
                  {o.members.length > 0 && <span className="muted small">{o.members.length} {o.members.length === 1 ? "candidate" : "candidates"}: {o.members.slice(0, 3).join(", ")}{o.members.length > 3 ? "…" : ""}</span>}
                </div>
                {editable && (
                  <span className="row-actions wrap">
                    <Button variant="secondary" aria-label={`Move ${o.label} up`} disabled={busy || i === 0} onClick={() => void move(i, -1)}>↑</Button>
                    <Button variant="secondary" aria-label={`Move ${o.label} down`} disabled={busy || i === options.length - 1} onClick={() => void move(i, 1)}>↓</Button>
                    <Button variant="secondary" disabled={busy} onClick={() => startEdit(o)}>Edit</Button>
                    {removing === o.id ? (
                      <>
                        <Button variant="danger" loading={busy} onClick={() => void remove(o.id)}>Remove</Button>
                        <Button variant="secondary" onClick={() => setRemoving(null)}>Cancel</Button>
                      </>
                    ) : <Button variant="secondary" disabled={busy} onClick={() => setRemoving(o.id)}>Remove</Button>}
                  </span>
                )}
              </li>
            ))}
          </ol>
        </Card>

        {editable && (
          <Card title={editing ? `Edit ${noun}` : `Add a ${noun}`}>
            <form onSubmit={onSubmit} noValidate>
              <Field label={listBased ? "List name" : "Candidate name"} value={label} onChange={(e) => setLabel(e.target.value)} error={errors.label} maxLength={120} autoComplete="off" />
              <TextAreaField label="Description (optional)" rows={2} value={description} onChange={(e) => setDescription(e.target.value)} error={errors.description} maxLength={500} />
              {listBased && (
                <TextAreaField label="Candidates on this list (optional)" rows={5} value={membersText} onChange={(e) => setMembersText(e.target.value)} error={errors.members}
                  hint="One name per line, in order. The first names on the list receive the seats the list wins." />
              )}
              <div className="row-actions wrap">
                <Button type="submit" loading={busy}>{editing ? "Save changes" : `Add ${noun}`}</Button>
                {editing && <Button variant="secondary" onClick={resetForm}>Cancel</Button>}
              </div>
            </form>
          </Card>
        )}
      </div>
      <Card title="Voter's view">
        <BallotPreview options={options ?? []} method={method} seats={election.seats} />
      </Card>
    </div>
  );
}
