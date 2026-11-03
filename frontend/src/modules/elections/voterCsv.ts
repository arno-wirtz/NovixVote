import type { VoterRow } from "../../types/api";

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
export const MAX_UPLOAD_ROWS = 10_000;

export interface ParsedVoters { rows: VoterRow[]; problems: { line: number; value: string; reason: string }[]; duplicates: number }

function splitLine(line: string, delimiter: string): string[] {
  const cells: string[] = [];
  let cur = ""; let quoted = false;
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (quoted) {
      if (ch === '"' && line[i + 1] === '"') { cur += '"'; i++; }
      else if (ch === '"') quoted = false;
      else cur += ch;
    } else if (ch === '"') quoted = true;
    else if (ch === delimiter) { cells.push(cur); cur = ""; }
    else cur += ch;
  }
  cells.push(cur);
  return cells.map((c) => c.trim());
}

function delimiterOf(line: string): string {
  const bare = line.replace(/"(?:[^"]|"")*"/g, "");   // delimiters inside quoted cells don't count
  if (bare.includes("\t")) return "\t";
  if (bare.includes(";") && !bare.includes(",")) return ";";
  return ",";
}

/** Parses pasted text or a CSV file: `email` or `email,name` per line, optional header, quoted names, comma/semicolon/tab. */
export function parseVoterText(input: string): ParsedVoters {
  const lines = input.replace(/^\uFEFF/, "").split(/\r?\n/);
  const rows: VoterRow[] = []; const problems: ParsedVoters["problems"] = []; const seen = new Set<string>();
  let duplicates = 0; let first = true;
  lines.forEach((raw, i) => {
    if (!raw.trim()) return;
    const cells = splitLine(raw, delimiterOf(raw));
    if (first) {
      first = false;
      if (/^e-?mail( address)?$/i.test(cells[0])) return;   // header row
    }
    if (rows.length + problems.length >= MAX_UPLOAD_ROWS) {
      if (problems[problems.length - 1]?.reason !== "Too many rows") problems.push({ line: i + 1, value: "", reason: "Too many rows" });
      return;
    }
    const email = cells[0].toLowerCase();
    const name = cells[1] || null;
    if (!EMAIL.test(email) || email.length > 254) problems.push({ line: i + 1, value: cells[0].slice(0, 60), reason: "Not a valid email address" });
    else if (name && name.length > 120) problems.push({ line: i + 1, value: cells[0], reason: "Name is longer than 120 characters" });
    else if (seen.has(email)) duplicates++;
    else { seen.add(email); rows.push({ email, name }); }
  });
  return { rows, problems, duplicates };
}

export function chunk<T>(items: T[], size: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size));
  return out;
}
