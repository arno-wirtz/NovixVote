/** One list candidate per line; blanks ignored. */
export const parseMembers = (text: string): string[] => text.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);

export function validateOption(label: string, description: string, members: string[], listBased: boolean): { label?: string; description?: string; members?: string } {
  const e: { label?: string; description?: string; members?: string } = {};
  if (!label.trim()) e.label = "Enter a name";
  else if (label.trim().length > 120) e.label = "Keep the name under 120 characters";
  if (description.length > 500) e.description = "Keep the description under 500 characters";
  if (listBased) {
    if (members.length > 100) e.members = "A list can have at most 100 candidates";
    else if (members.some((m) => m.length > 120)) e.members = "Each candidate name must be under 120 characters";
    else if (new Set(members.map((m) => m.toLowerCase())).size !== members.length) e.members = "A candidate appears twice in this list";
  }
  return e;
}

/** New order of ids after moving the item at `index` by `delta` (-1 up, +1 down); unchanged at the ends. */
export function moveItem(ids: string[], index: number, delta: -1 | 1): string[] {
  const to = index + delta;
  if (index < 0 || index >= ids.length || to < 0 || to >= ids.length) return ids;
  const next = [...ids];
  [next[index], next[to]] = [next[to], next[index]];
  return next;
}
