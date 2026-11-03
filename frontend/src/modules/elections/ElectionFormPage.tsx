import { useEffect, useRef, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { useAuth } from "../../app/providers/AuthProvider";
import { Alert, Button, Card, Field, TextAreaField } from "../../components/ui/ui";
import { ApiError } from "../../services/api";
import type { VotingMethod } from "../../types/api";
import { useOrgContext } from "../organisations/useOrgContext";
import { STEPS, emptyState, stateFromElection, toInput, validateStep, type WizardErrors, type WizardState } from "./wizard";
import { formatDateTime } from "./lifecycle";

/** Creation wizard and (for drafts) the edit form: the same four steps. */
export function ElectionFormPage() {
  const { orgId, can } = useOrgContext();
  const { electionId } = useParams();
  const editing = Boolean(electionId);
  const { api } = useAuth();
  const navigate = useNavigate();
  const [methods, setMethods] = useState<VotingMethod[] | null>(null);
  const [state, setState] = useState<WizardState>(emptyState());
  const [step, setStep] = useState(0);
  const [errors, setErrors] = useState<WizardErrors>({});
  const [formError, setFormError] = useState<string | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const heading = useRef<HTMLHeadingElement>(null);

  useEffect(() => {
    api.votingMethods().then(setMethods).catch(() => setLoadError("Couldn't load voting systems"));
    if (electionId) api.election(electionId).then((e) => setState(stateFromElection(e))).catch(() => setLoadError("Couldn't load the election"));
  }, [api, electionId]);
  useEffect(() => { heading.current?.focus(); }, [step]);

  const allowed = editing ? can("election.manage") : can("election.create");
  if (!allowed) return <Alert tone="danger">You don't have permission to {editing ? "edit" : "create"} elections in this workspace.</Alert>;
  if (loadError) return <Alert tone="danger">{loadError}</Alert>;
  if (!methods) return <p className="muted" role="status">Loading…</p>;

  const method = methods.find((m) => m.key === state.votingMethod);
  const set = <K extends keyof WizardState>(k: K, v: WizardState[K]) => { setState((s) => ({ ...s, [k]: v })); setErrors((e) => ({ ...e, [k]: undefined })); };

  function chooseMethod(m: VotingMethod) {
    setState((s) => ({ ...s, votingMethod: m.key, seats: m.max_seats != null ? String(m.max_seats) : s.seats, threshold: m.supports_threshold ? s.threshold : "" }));
    setErrors((e) => ({ ...e, votingMethod: undefined, seats: undefined }));
  }

  function next() {
    const errs = validateStep(step, state, methods!);
    setErrors(errs);
    if (Object.keys(errs).length === 0) setStep((s) => s + 1);
  }

  async function submit() {
    for (let i = 0; i < 3; i++) {
      const errs = validateStep(i, state, methods!);
      if (Object.keys(errs).length) { setErrors(errs); setStep(i); return; }
    }
    setBusy(true); setFormError(null);
    try {
      const input = toInput(state, methods!);
      const saved = editing ? await api.updateElection(electionId!, input) : await api.createElection(orgId, input);
      navigate(`/workspaces/${orgId}/elections/${saved.id}`);
    } catch (e) { setFormError(e instanceof ApiError ? e.message : "Couldn't save the election"); setBusy(false); }
  }

  return (
    <Card>
      <nav aria-label="Progress" className="steps">
        <ol>{STEPS.map((label, i) => (
          <li key={label} aria-current={i === step ? "step" : undefined} className={i === step ? "is-current" : i < step ? "is-done" : ""}>
            <span className="step-num" aria-hidden="true">{i < step ? "✓" : i + 1}</span>{label}
          </li>))}
        </ol>
      </nav>
      <h2 ref={heading} tabIndex={-1} className="step-title">{editing ? "Edit draft: " : ""}{STEPS[step]}</h2>
      {formError && <Alert tone="danger">{formError}</Alert>}

      {step === 0 && (
        <div className="reading-container">
          <Field label="Election title" value={state.title} onChange={(e) => set("title", e.target.value)} error={errors.title} maxLength={120} autoComplete="off" />
          <TextAreaField label="Description (optional)" value={state.description} onChange={(e) => set("description", e.target.value)} error={errors.description}
            hint="Shown to voters. Explain what is being decided." maxLength={2000} />
        </div>
      )}

      {step === 1 && (
        <div className="reading-container">
          <fieldset className="choice-group" aria-describedby={errors.votingMethod ? "method-err" : undefined}>
            <legend>Voting system</legend>
            {methods.map((m) => (
              <label key={m.key} className={`choice ${state.votingMethod === m.key ? "is-selected" : ""}`}>
                <input type="radio" name="method" value={m.key} checked={state.votingMethod === m.key} onChange={() => chooseMethod(m)} />
                <span><strong>{m.name}</strong><span className="muted small">{m.description}</span>
                  <span className="muted small">{({ party_list: "Voters choose one list.", ranked: "Voters rank candidates in order of preference.", candidate: "Voters choose candidates." } as Record<string, string>)[m.ballot_type]}</span></span>
              </label>
            ))}
            {errors.votingMethod && <p id="method-err" className="field-error" role="alert">{errors.votingMethod}</p>}
          </fieldset>
          <Field label={method?.category === "proportional" ? "Seats to distribute" : "Seats to fill"} type="number" min={1} max={100} inputMode="numeric"
            value={state.seats} onChange={(e) => set("seats", e.target.value)} error={errors.seats} readOnly={method?.max_seats === 1}
            hint={method?.key === "plurality" ? "Voters can select up to this many candidates." : method?.max_seats === 1 ? `${method.name} elects exactly one winner.` : undefined} />
          {method?.supports_threshold && (
            <Field label="Electoral threshold, % (optional)" type="number" min={0} max={100} step="any" inputMode="decimal"
              value={state.threshold} onChange={(e) => set("threshold", e.target.value)} error={errors.threshold}
              hint="Lists below this share of valid votes win no seats. Leave empty for no threshold." />
          )}
        </div>
      )}

      {step === 2 && (
        <div className="reading-container">
          <fieldset className="choice-group">
            <legend>Who can vote</legend>
            {([["restricted", "Restricted", "Only people on the voter list you upload can vote, matched by their confirmed email address."], ["public", "Public", "Anyone with a NovixVote account and the link can vote, one vote per account. It can't verify that each person has only one account, so it suits polls rather than binding decisions."]] as const).map(([v, name, help]) => (
              <label key={v} className={`choice ${state.access === v ? "is-selected" : ""}`}>
                <input type="radio" name="access" value={v} checked={state.access === v} onChange={() => set("access", v)} />
                <span><strong>{name}</strong><span className="muted small">{help}</span></span>
              </label>
            ))}
          </fieldset>
          <Field label="Voting opens" type="datetime-local" value={state.opensAt} onChange={(e) => set("opensAt", e.target.value)} error={errors.opensAt} />
          <Field label="Voting closes" type="datetime-local" value={state.closesAt} onChange={(e) => set("closesAt", e.target.value)} error={errors.closesAt}
            hint={`Times are in your time zone (${Intl.DateTimeFormat().resolvedOptions().timeZone}). You can leave both empty now, but you need both to schedule the election.`} />
        </div>
      )}

      {step === 3 && (
        <div className="reading-container">
          <dl className="summary">
            <dt>Title</dt><dd>{state.title.trim()}</dd>
            <dt>Description</dt><dd>{state.description.trim() || "None"}</dd>
            <dt>Voting system</dt><dd>{method?.name}</dd>
            <dt>Seats</dt><dd>{state.seats}</dd>
            {method?.supports_threshold && <><dt>Threshold</dt><dd>{state.threshold.trim() ? `${state.threshold}%` : "None"}</dd></>}
            <dt>Who can vote</dt><dd>{state.access === "public" ? "Anyone with an account and the link" : "People on the voter list"}</dd>
            <dt>Opens</dt><dd>{state.opensAt ? formatDateTime(new Date(state.opensAt).toISOString()) : "Not set"}</dd>
            <dt>Closes</dt><dd>{state.closesAt ? formatDateTime(new Date(state.closesAt).toISOString()) : "Not set"}</dd>
          </dl>
          <p className="muted small">{editing ? "Saving keeps this election as a draft." : "The election is created as a draft that only election managers can see. Next you'll build the ballot and add voters, then schedule it."}</p>
        </div>
      )}

      <div className="wizard-nav">
        <Button variant="secondary" disabled={busy} onClick={() => (step === 0 ? navigate(-1) : setStep(step - 1))}>{step === 0 ? "Cancel" : "Back"}</Button>
        {step < 3 ? <Button onClick={next}>Continue</Button> : <Button loading={busy} onClick={() => void submit()}>{editing ? "Save changes" : "Create draft election"}</Button>}
      </div>
    </Card>
  );
}
