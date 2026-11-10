/** Client-side mirror of the checks in cast_vote(), for instant feedback only. The database is the authority. */
export function validateSelection(kind: string, seats: number, selected: string[], allowBlank: boolean): string | null {
  if (new Set(selected).size !== selected.length) return "You can't select the same option twice";
  if (selected.length === 0) return allowBlank ? null : "Select at least one option to cast your vote";
  if (kind === "party_list" && selected.length > 1) return "Choose one list";
  if (kind === "candidate" && selected.length > seats) return `Select at most ${seats} ${seats === 1 ? "candidate" : "candidates"}`;
  return null;
}

/** Ranks chosen per option id ("" = not ranked) -> option ids in rank order. Each rank may be used once. */
export function rankingToSelection(ranks: Record<string, string>): { selection: string[]; error: string | null } {
  const ranked = Object.entries(ranks).filter(([, r]) => r !== "").map(([id, r]) => ({ id, rank: Number(r) }));
  if (new Set(ranked.map((x) => x.rank)).size !== ranked.length) return { selection: [], error: "Each rank can only be used once" };
  return { selection: ranked.sort((a, b) => a.rank - b.rank).map((x) => x.id), error: null };
}

/** Option ids -> rank strings, for pre-filling the ranking form from a saved vote. */
export function selectionToRanks(selection: string[]): Record<string, string> {
  return Object.fromEntries(selection.map((id, i) => [id, String(i + 1)]));
}
