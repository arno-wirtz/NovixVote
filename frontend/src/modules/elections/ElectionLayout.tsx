import { useEffect, useState } from "react";
import { Link, NavLink, Outlet, useOutletContext, useParams } from "react-router-dom";
import { useAuth } from "../../app/providers/AuthProvider";
import { Alert, StatusBadge } from "../../components/ui/ui";
import { ApiError } from "../../services/api";
import type { Election, VotingMethod } from "../../types/api";
import type { OrgContext } from "../organisations/OrgLayout";
import { useOrgContext } from "../organisations/useOrgContext";
import { STATUS_LABEL, STATUS_TONE } from "./lifecycle";

export interface ElectionContext extends OrgContext { election: Election; setElection: (e: Election) => void; method: VotingMethod | undefined; reload: () => Promise<void> }
export const useElectionContext = () => useOutletContext<ElectionContext>();

export function ElectionLayout() {
  const org = useOrgContext();
  const { electionId = "" } = useParams();
  const { api } = useAuth();
  const [election, setElection] = useState<Election | null>(null);
  const [methods, setMethods] = useState<VotingMethod[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [notFound, setNotFound] = useState(false);

  const reload = () => api.election(electionId).then(setElection).catch((e) => {
    if (e instanceof ApiError && e.status === 404) setNotFound(true); else setError("Couldn't load the election");
  });
  useEffect(() => { setElection(null); void reload(); api.votingMethods().then(setMethods).catch(() => undefined); }, [electionId, api]); // eslint-disable-line react-hooks/exhaustive-deps
  // Scheduled/open elections change status on their own at the opening/closing time.
  useEffect(() => {
    if (!election || (election.status !== "scheduled" && election.status !== "open")) return;
    const t = window.setInterval(() => void reload(), 30_000);
    return () => window.clearInterval(t);
  }, [election?.status]); // eslint-disable-line react-hooks/exhaustive-deps

  if (notFound) return <Alert tone="danger">This election doesn't exist, or you don't have access to it.</Alert>;
  if (!election) return error ? <Alert tone="danger">{error}</Alert> : <p className="muted" role="status">Loading…</p>;

  const base = `/workspaces/${org.orgId}/elections/${election.id}`;
  const showVoters = org.can("election.manage") && election.access === "restricted";
  const showResults = org.can("results.view") && (election.status === "closed" || election.status === "published");
  const ctx: ElectionContext = { ...org, election, setElection, method: methods.find((m) => m.key === election.voting_method), reload };
  const tab = ({ isActive }: { isActive: boolean }) => `tab ${isActive ? "is-active" : ""}`;
  return (
    <>
      <p className="small"><Link to={`/workspaces/${org.orgId}/elections`}>← All elections</Link></p>
      <div className="card-head"><h2 className="election-title">{election.title}</h2><StatusBadge tone={STATUS_TONE[election.status]}>{STATUS_LABEL[election.status]}</StatusBadge></div>
      <nav className="tabs" aria-label="Election sections">
        <NavLink end to={base} className={tab}>Overview</NavLink>
        <NavLink to={`${base}/ballot`} className={tab}>Ballot</NavLink>
        {showVoters && <NavLink to={`${base}/voters`} className={tab}>Voters</NavLink>}
        {showResults && <NavLink to={`${base}/results`} className={tab}>Results</NavLink>}
      </nav>
      <Outlet context={ctx} />
    </>
  );
}
