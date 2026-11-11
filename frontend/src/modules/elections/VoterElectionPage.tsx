import { useEffect, useState } from "react";
import { useParams } from "react-router-dom";
import { useAuth } from "../../app/providers/AuthProvider";
import { Alert, Card, StatusBadge } from "../../components/ui/ui";
import { ApiError } from "../../services/api";
import type { BallotOption, Election, PublishedResult, VotingMethod } from "../../types/api";
import { BallotPreview } from "./BallotPreview";
import { CastBallot } from "./CastBallot";
import { ResultView } from "./ResultView";
import { STATUS_LABEL, STATUS_TONE, formatDateTime } from "./lifecycle";

/** What an eligible voter (workspace member or not) sees when they open an election link. */
export function VoterElectionPage() {
  const { electionId = "" } = useParams();
  const { api } = useAuth();
  const [election, setElection] = useState<Election | null>(null);
  const [options, setOptions] = useState<BallotOption[]>([]);
  const [method, setMethod] = useState<VotingMethod | undefined>();
  const [eligible, setEligible] = useState<boolean | null>(null);
  const [published, setPublished] = useState<PublishedResult | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    api.election(electionId).then(async (e) => {
      setElection(e);
      const [ballot, methods, elig] = await Promise.all([api.ballot(electionId), api.votingMethods(), api.eligibility(electionId)]);
      setOptions(ballot); setMethod(methods.find((m) => m.key === e.voting_method)); setEligible(elig.eligible);
      if (e.status === "published") setPublished(await api.results(electionId).catch(() => null));
    }).catch((e) => setError(e instanceof ApiError && e.status === 404 ? "This election doesn't exist, or you don't have access to it." : "Couldn't load the election"));
  }, [api, electionId]);

  if (error) return <Alert tone="danger">{error}</Alert>;
  if (!election) return <p className="muted" role="status">Loading…</p>;

  const status = {
    scheduled: `Voting opens ${formatDateTime(election.opens_at)}.`,
    open: `Voting is open until ${formatDateTime(election.closes_at)}.`,
    closed: "Voting has closed.",
    published: "Voting has closed and the approved results are below.",
    draft: "This election is still being prepared.",
  }[election.status];
  const canVote = election.status === "open" && eligible === true;

  return (
    <>
      <p className="muted small">{election.organisation_name}</p>
      <div className="card-head"><h1>{election.title}</h1><StatusBadge tone={STATUS_TONE[election.status]}>{STATUS_LABEL[election.status]}</StatusBadge></div>
      {election.description && <p className="lead">{election.description}</p>}
      {eligible === true && <Alert tone="success">You're eligible to vote in this election.</Alert>}
      {eligible === false && <Alert tone="info">{election.access === "restricted" ? "Your email address isn't on this election's voter list." : "Confirm your email address to take part."}</Alert>}
      <Card title="When"><p>{status}</p>
        <dl className="summary"><dt>Opens</dt><dd>{formatDateTime(election.opens_at)}</dd><dt>Closes</dt><dd>{formatDateTime(election.closes_at)}</dd><dt>Seats</dt><dd>{election.seats}</dd>
          <dt>Blank ballots</dt><dd>{election.allow_blank_ballot ? "Allowed" : "Not allowed: you must select at least one option"}</dd>
          <dt>Changing your vote</dt><dd>{election.allow_vote_change ? "Allowed until voting closes" : "Not allowed after you submit"}</dd></dl>
      </Card>
      {published && (
        <Card title="Results">
          {published.result ? <ResultView result={published.result} tieBreak={published.tie_break} /> : <p className="muted">No ballots were cast in this election.</p>}
          {published.result && <p className="muted small">Based on {published.ballot_count} ballots. Counts only: individual votes are not recorded against anyone.</p>}
        </Card>
      )}
      {canVote
        ? <Card title="Your ballot"><CastBallot election={election} options={options} method={method} /></Card>
        : <Card title="Ballot"><BallotPreview options={options} method={method} seats={election.seats} /></Card>}
    </>
  );
}
