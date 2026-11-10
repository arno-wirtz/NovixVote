import type { BallotOption, VotingMethod } from "../../types/api";

/** Non-interactive rendering of the ballot as a voter will see it. */
export function BallotPreview({ options, method, seats }: { options: BallotOption[]; method: VotingMethod | undefined; seats: number }) {
  const lists = method?.ballot_type === "party_list";
  const ranked = method?.ballot_type === "ranked";
  const type = lists ? "radio" : "checkbox";
  return (
    <div className="ballot-preview" role="group" aria-label="Ballot preview">
      <p className="small muted">{lists ? "Choose one list." : ranked ? "Rank as many candidates as you like, with 1 as your first choice." : `Choose up to ${seats} ${seats === 1 ? "candidate" : "candidates"}.`} <strong>Preview only: nothing can be selected here.</strong></p>
      {options.length === 0 && <p className="muted">The ballot is empty.</p>}
      <ul className="ballot-options">
        {options.map((o) => (
          <li key={o.id}>
            <label className="ballot-option">
              {ranked
                ? <select disabled aria-label={`Rank for ${o.label}`} className="rank-select"><option>Rank</option></select>
                : <input type={type} disabled aria-label={o.label} />}
              <span><strong>{o.label}</strong>
                {o.description && <span className="muted small">{o.description}</span>}
                {o.members.length > 0 && <ol className="members small">{o.members.map((m) => <li key={m}>{m}</li>)}</ol>}
              </span>
            </label>
          </li>
        ))}
      </ul>
    </div>
  );
}
