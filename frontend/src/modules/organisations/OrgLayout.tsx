import { useEffect, useState } from "react";
import { NavLink, Outlet, useParams } from "react-router-dom";
import { useAuth } from "../../app/providers/AuthProvider";
import { Alert } from "../../components/ui/ui";
import { ApiError } from "../../services/api";
import type { Membership } from "../../types/api";
import { ROLE_LABEL } from "./roles";

export interface OrgContext { orgId: string; orgName: string; membership: Membership; can: (permission: string) => boolean }

export function OrgLayout() {
  const { orgId = "" } = useParams();
  const { api } = useAuth();
  const [state, setState] = useState<{ name: string; membership: Membership } | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    setState(null); setError(null);
    Promise.all([api.membership(orgId), api.organisations()])
      .then(([membership, orgs]) => setState({ membership, name: orgs.find((o) => o.id === orgId)?.name ?? "Workspace" }))
      .catch((e) => setError(e instanceof ApiError && e.status === 404 ? "This workspace doesn't exist, or you aren't a member." : "Couldn't load the workspace"));
  }, [api, orgId]);

  if (error) return <Alert tone="danger">{error}</Alert>;
  if (!state) return <p className="muted" role="status">Loading…</p>;
  const ctx: OrgContext = { orgId, orgName: state.name, membership: state.membership, can: (p) => state.membership.permissions.includes(p) };
  return (
    <>
      <p className="breadcrumb muted small">Workspace · {ROLE_LABEL[state.membership.role]}</p>
      <h1>{state.name}</h1>
      <nav className="tabs" aria-label="Workspace sections">
        <NavLink to={`/workspaces/${orgId}/elections`} className={({ isActive }) => `tab ${isActive ? "is-active" : ""}`}>Elections</NavLink>
        <NavLink to={`/workspaces/${orgId}/members`} className={({ isActive }) => `tab ${isActive ? "is-active" : ""}`}>Members</NavLink>
      </nav>
      <Outlet context={ctx} />
    </>
  );
}
