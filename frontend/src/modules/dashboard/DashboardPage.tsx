import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { useAuth } from "../../app/providers/AuthProvider";
import { Card, StatusBadge } from "../../components/ui/ui";
import { ApiError } from "../../services/api";
import type { Health, MyElection, VotingMethod } from "../../types/api";
import { STATUS_LABEL, STATUS_TONE, formatDateTime } from "../elections/lifecycle";
import { useOrganisations } from "../organisations/useOrganisations";
import { InvitationsInbox } from "../members/InvitationsInbox";
import { ROLE_LABEL } from "../organisations/roles";

export function DashboardPage() {
  const { api } = useAuth();
  const { items, error, reload } = useOrganisations();
  const [health, setHealth] = useState<Health | null>(null);
  const [healthError, setHealthError] = useState<string | null>(null);
  const [methods, setMethods] = useState<VotingMethod[] | null>(null);
  const [mine, setMine] = useState<MyElection[]>([]);

  useEffect(() => {
    api.health().then(setHealth).catch((e) => setHealthError(e instanceof ApiError ? e.message : "Unavailable"));
    api.votingMethods().then(setMethods).catch(() => setMethods([]));
    api.myElections().then(setMine).catch(() => setMine([]));
  }, [api]);

  return (
    <>
      <h1>Dashboard</h1>
      <p className="muted lead">Your workspaces and the state of the platform.</p>

      <InvitationsInbox onChange={() => void reload()} />

      {mine.length > 0 && (
        <Card title="Elections you can vote in">
          <ul className="list">
            {mine.map((e) => (
              <li key={e.id}>
                <div><Link to={`/elections/${e.id}`}><strong>{e.title}</strong></Link><span className="muted small">{e.organisation_name} · {formatDateTime(e.opens_at)} – {formatDateTime(e.closes_at)}</span></div>
                <StatusBadge tone={STATUS_TONE[e.status]}>{STATUS_LABEL[e.status]}</StatusBadge>
              </li>
            ))}
          </ul>
        </Card>
      )}

      <div className="grid-3">
        <Card title="Workspaces">
          <p className="metric">{items ? items.length : "–"}</p>
          {error ? <StatusBadge tone="danger">Couldn't load</StatusBadge> : <Link to="/workspaces">Manage workspaces</Link>}
        </Card>
        <Card title="Platform">
          {health && <><p className="metric small-metric">v{health.version}</p><StatusBadge tone="success">API online</StatusBadge></>}
          {healthError && <StatusBadge tone="danger">API unreachable</StatusBadge>}
          {!health && !healthError && <p className="muted" role="status">Checking…</p>}
        </Card>
        <Card title="Elections">
          <p className="muted small">Open a workspace to create and run elections.</p>
          <StatusBadge tone="neutral">Create elections inside a workspace</StatusBadge>
        </Card>
      </div>

      <div className="grid-2">
        <Card title="Your roles">
          {items && items.length === 0 && <p className="muted">No workspaces yet. <Link to="/workspaces">Create your first workspace</Link>.</p>}
          {items && items.length > 0 && (
            <ul className="list">{items.map((o) => <li key={o.id}><strong>{o.name}</strong><StatusBadge tone="info">{ROLE_LABEL[o.role]}</StatusBadge></li>)}</ul>
          )}
        </Card>
        <Card title="Registered voting methods">
          {methods && methods.length === 0 && <p className="muted">None available.</p>}
          {methods && methods.length > 0 && (
            <ul className="list">{methods.map((m) => <li key={m.key}><div><strong>{m.name}</strong><span className="muted small">{m.description}</span></div></li>)}</ul>
          )}
          <p className="muted small">Majority/runoff is added to this registry in a later phase.</p>
        </Card>
      </div>
    </>
  );
}
