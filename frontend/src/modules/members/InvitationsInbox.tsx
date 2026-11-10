import { useCallback, useEffect, useState } from "react";
import { useAuth } from "../../app/providers/AuthProvider";
import { Alert, Button, Card } from "../../components/ui/ui";
import { ApiError } from "../../services/api";
import type { MyInvitation } from "../../types/api";
import { ROLE_LABEL } from "../organisations/roles";

/** Pending invitations addressed to the signed-in user's verified email. Renders nothing when there are none. */
export function InvitationsInbox({ onChange }: { onChange?: () => void }) {
  const { api } = useAuth();
  const [items, setItems] = useState<MyInvitation[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);

  const load = useCallback(() => api.myInvitations().then(setItems).catch(() => setItems([])), [api]);
  useEffect(() => { void load(); }, [load]);

  async function respond(id: string, accept: boolean) {
    setBusy(id); setError(null);
    try {
      await (accept ? api.acceptInvitation(id) : api.declineInvitation(id));
      await load();
      onChange?.();
    } catch (e) { setError(e instanceof ApiError ? e.message : "Couldn't update the invitation"); }
    finally { setBusy(null); }
  }

  if (items.length === 0 && !error) return null;
  return (
    <Card title="Invitations for you">
      {error && <Alert tone="danger">{error}</Alert>}
      <ul className="list">
        {items.map((i) => (
          <li key={i.id}>
            <div><strong>{i.organisation_name}</strong><span className="muted small">Join as {ROLE_LABEL[i.role].toLowerCase()}</span></div>
            <span className="row-actions">
              <Button loading={busy === i.id} onClick={() => void respond(i.id, true)}>Accept</Button>
              <Button variant="secondary" disabled={busy === i.id} onClick={() => void respond(i.id, false)}>Decline</Button>
            </span>
          </li>
        ))}
      </ul>
    </Card>
  );
}
