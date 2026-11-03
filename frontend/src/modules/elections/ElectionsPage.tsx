import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { useAuth } from "../../app/providers/AuthProvider";
import { Alert, Card, StatusBadge } from "../../components/ui/ui";
import { ApiError } from "../../services/api";
import type { Election, VotingMethod } from "../../types/api";
import { useOrgContext } from "../organisations/useOrgContext";
import { STATUS_LABEL, STATUS_TONE, formatDateTime } from "./lifecycle";

export function ElectionsPage() {
  const { orgId, can } = useOrgContext();
  const { api } = useAuth();
  const [items, setItems] = useState<Election[] | null>(null);
  const [methods, setMethods] = useState<VotingMethod[]>([]);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    api.elections(orgId).then(setItems).catch((e) => setError(e instanceof ApiError ? e.message : "Couldn't load elections"));
    api.votingMethods().then(setMethods).catch(() => setMethods([]));
  }, [api, orgId]);

  const methodName = (k: string) => methods.find((m) => m.key === k)?.name ?? k;
  return (
    <Card title="Elections" action={can("election.create") ? <Link className="btn btn-primary" to={`/workspaces/${orgId}/elections/new`}>Create election</Link> : undefined}>
      {error && <Alert tone="danger">{error}</Alert>}
      {!items && !error && <p className="muted" role="status">Loading…</p>}
      {items?.length === 0 && <p className="muted">{can("election.create") ? "No elections yet. Create your first one." : "No elections are available to you yet."}</p>}
      {items && items.length > 0 && (
        <ul className="list">
          {items.map((e) => (
            <li key={e.id}>
              <div>
                <Link to={`/workspaces/${orgId}/elections/${e.id}`}><strong>{e.title}</strong></Link>
                <span className="muted small">{methodName(e.voting_method)} · {e.seats} {e.seats === 1 ? "seat" : "seats"} · {e.opens_at ? `${formatDateTime(e.opens_at)} – ${formatDateTime(e.closes_at)}` : "No schedule yet"}</span>
              </div>
              <StatusBadge tone={STATUS_TONE[e.status]}>{STATUS_LABEL[e.status]}</StatusBadge>
            </li>
          ))}
        </ul>
      )}
    </Card>
  );
}
