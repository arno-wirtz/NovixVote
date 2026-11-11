import type { CountResult } from "../../types/api";

export interface ResultRow { name: string; votes: number; share: number | null; seats: number | null; elected: boolean }

/** Table rows for a count, highest first. Share is of valid ballots (rounded to 0.1). Seats only for seat-allocation methods. */
export function resultRows(r: CountResult): ResultRow[] {
  const seatBased = r.category === "proportional";
  return r.candidates
    .map((name, i) => ({ name, i, votes: r.tallies[name] ?? 0 }))
    .sort((a, b) => b.votes - a.votes || a.i - b.i)
    .map(({ name, votes }) => ({
      name, votes,
      share: r.valid_ballots > 0 ? Math.round((votes / r.valid_ballots) * 1000) / 10 : null,
      seats: seatBased ? r.allocations[name] ?? 0 : null,
      elected: r.winners.includes(name),
    }));
}

export const METHOD_LABEL: Record<string, string> = {
  plurality: "Plurality", d_hondt: "D'Hondt", sainte_lague: "Sainte-Laguë", irv: "Instant-runoff",
};
export const TIE_METHOD_LABEL: Record<string, string> = { lots: "Drawing lots", agreed_order: "Agreed order", other: "Other procedure" };
