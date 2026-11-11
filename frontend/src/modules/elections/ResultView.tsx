import { Alert, StatusBadge } from "../../components/ui/ui";
import type { CountResult, TieBreakRecord } from "../../types/api";
import { METHOD_LABEL, TIE_METHOD_LABEL, resultRows } from "./resultRows";

/** Aggregate result of a count. Status is always written out (never colour alone); IRV shows every round so the count can be replayed by hand. */
export function ResultView({ result, tieBreak }: { result: CountResult; tieBreak?: TieBreakRecord | null }) {
  const rows = resultRows(result);
  const seatBased = result.category === "proportional";
  const irv = result.method === "irv";
  return (
    <div className="result-view">
      <p className="muted small">{METHOD_LABEL[result.method] ?? result.method} · {result.seats} {result.seats === 1 ? "seat" : "seats"}</p>
      {!result.complete && (
        <Alert tone="danger">There is an unresolved tie between {result.tied_for_last_seat.join(", ")}. Record how it was broken and count again.</Alert>
      )}
      {result.complete && (
        <p><strong>{result.winners.length === 0 ? "No winner: no valid votes were cast." : `Elected: ${result.winners.join(", ")}`}</strong></p>
      )}
      {seatBased && result.unallocated_seats > 0 && result.complete && <p className="muted small">{result.unallocated_seats} {result.unallocated_seats === 1 ? "seat" : "seats"} could not be allocated.</p>}
      <table className="result-table">
        <caption className="sr-only">Votes per {seatBased ? "list" : "candidate"}</caption>
        <thead><tr><th scope="col">{seatBased ? "List" : "Candidate"}</th><th scope="col">{irv ? "First-choice votes" : "Votes"}</th><th scope="col">Share</th>{seatBased && <th scope="col">Seats</th>}<th scope="col">Result</th></tr></thead>
        <tbody>
          {rows.map((r) => (
            <tr key={r.name}>
              <th scope="row">{r.name}</th><td>{r.votes}</td><td>{r.share == null ? "–" : `${r.share}%`}</td>{seatBased && <td>{r.seats}</td>}
              <td>{r.elected ? <StatusBadge tone="success">Elected</StatusBadge> : result.below_threshold.includes(r.name) ? <StatusBadge tone="neutral">Below threshold</StatusBadge> : "–"}</td>
            </tr>
          ))}
        </tbody>
      </table>
      <p className="muted small">Valid ballots {result.valid_ballots} · blank {result.blank_ballots} · invalid {result.invalid_ballots}</p>

      {irv && result.rounds.length > 0 && (
        <details>
          <summary>Round-by-round count ({result.rounds.length} {result.rounds.length === 1 ? "round" : "rounds"})</summary>
          <p className="muted small">Each round counts every ballot for its highest-ranked remaining candidate. Ballots with no remaining choice are exhausted. A candidate wins with more than half of the ballots still active.</p>
          <table className="result-table">
            <thead><tr><th scope="col">Round</th>{result.candidates.map((c) => <th key={c} scope="col">{c}</th>)}<th scope="col">Exhausted</th><th scope="col">Eliminated</th></tr></thead>
            <tbody>
              {result.rounds.map((rd) => (
                <tr key={rd.round}>
                  <th scope="row">{rd.round}</th>{result.candidates.map((c) => <td key={c}>{c in rd.tallies ? rd.tallies[c] : "–"}</td>)}
                  <td>{rd.exhausted}</td><td>{rd.winner ? `Winner: ${rd.winner}` : rd.eliminated.length ? rd.eliminated.join(", ") + (rd.tie_resolution ? ` (tie: ${rd.tie_resolution === "tie_break_order" ? "recorded tie-break" : "previous-round rule"})` : "") : "–"}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </details>
      )}
      {seatBased && result.allocation_log.length > 0 && (
        <details>
          <summary>Seat-by-seat allocation</summary>
          <p className="muted small">Each seat goes to the list with the highest quotient: votes divided by the divisor for the seats it already holds.</p>
          <table className="result-table">
            <thead><tr><th scope="col">Seat</th><th scope="col">List</th><th scope="col">Votes</th><th scope="col">Divisor</th><th scope="col">Quotient</th></tr></thead>
            <tbody>{result.allocation_log.map((a, i) => <tr key={i}><th scope="row">{a.seat}</th><td>{a.list}</td><td>{a.votes}</td><td>{a.divisor}</td><td>{a.quotient}</td></tr>)}</tbody>
          </table>
        </details>
      )}
      {tieBreak && (
        <p className="small"><strong>Tie broken by {TIE_METHOD_LABEL[tieBreak.method] ?? tieBreak.method}.</strong> {tieBreak.note} Order used: {tieBreak.order.join(" → ")}.</p>
      )}
    </div>
  );
}
