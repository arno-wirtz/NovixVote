import { useState, type FormEvent } from "react";
import { Link } from "react-router-dom";
import { useAuth } from "../../app/providers/AuthProvider";
import { Alert, Button, Card, Field } from "../../components/ui/ui";
import { ApiError } from "../../services/api";
import { InvitationsInbox } from "../members/InvitationsInbox";
import { ROLE_LABEL } from "./roles";
import { useOrganisations } from "./useOrganisations";

export function WorkspacesPage() {
  const { api } = useAuth();
  const { items, error, reload } = useOrganisations();
  const [name, setName] = useState("");
  const [slug, setSlug] = useState("");
  const [fieldError, setFieldError] = useState<string | null>(null);
  const [formError, setFormError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    setFormError(null); setFieldError(null);
    if (name.trim().length < 2) { setFieldError("Enter a workspace name of at least 2 characters"); return; }
    setBusy(true);
    try { await api.createOrganisation(name.trim(), slug.trim().toLowerCase()); setName(""); setSlug(""); await reload(); }
    catch (err) { setFormError(err instanceof ApiError ? err.message : "Could not create workspace"); }
    finally { setBusy(false); }
  }

  return (
    <>
      <h1>Workspaces</h1>
      <p className="muted lead">Each workspace is a separate organisation with its own members, elections and audit trail.</p>
      <InvitationsInbox onChange={() => void reload()} />
      <div className="grid-2">
        <Card title="Your workspaces">
          {error && <Alert tone="danger">{error}</Alert>}
          {!items && !error && <p role="status" className="muted">Loading…</p>}
          {items && items.length === 0 && <p className="muted">You don't belong to a workspace yet. Create one to get started.</p>}
          {items && items.length > 0 && (
            <ul className="list">
              {items.map((o) => (
                <li key={o.id}>
                  <div><strong>{o.name}</strong><span className="muted small">{ROLE_LABEL[o.role]}</span></div>
                  <span className="row-actions">
                    <Link to={`/workspaces/${o.id}/elections`}>Elections</Link>
                    <Link to={`/workspaces/${o.id}/members`}>Members</Link>
                  </span></li>
              ))}
            </ul>
          )}
        </Card>
        <Card title="Create a workspace">
          {formError && <Alert tone="danger">{formError}</Alert>}
          <form onSubmit={onSubmit} noValidate>
            <Field label="Workspace name" value={name} onChange={(e) => setName(e.target.value)} error={fieldError} maxLength={80} />
            <Field label="Address (optional)" value={slug} onChange={(e) => setSlug(e.target.value)}
              hint="Lowercase letters, numbers and hyphens. Generated from the name if left empty." maxLength={48} />
            <Button type="submit" loading={busy}>Create workspace</Button>
          </form>
        </Card>
      </div>
    </>
  );
}
