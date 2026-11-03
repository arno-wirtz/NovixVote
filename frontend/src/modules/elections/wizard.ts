import type { Election, ElectionAccess, ElectionInput, VotingMethod } from "../../types/api";

export interface WizardState {
  title: string; description: string; votingMethod: string; seats: string; threshold: string;
  access: ElectionAccess; opensAt: string; closesAt: string; // opensAt/closesAt are <input type="datetime-local"> values
}
export type WizardErrors = Partial<Record<keyof WizardState, string>>;
export const STEPS = ["Basics", "Voting system", "Access and schedule", "Review"] as const;

export const emptyState = (): WizardState => ({
  title: "", description: "", votingMethod: "", seats: "1", threshold: "", access: "restricted", opensAt: "", closesAt: "",
});

/** ISO string -> value for <input type="datetime-local"> in the viewer's local time. */
export function toLocalInput(iso: string | null): string {
  if (!iso) return "";
  const d = new Date(iso);
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`;
}
export const fromLocalInput = (v: string): string | null => (v ? new Date(v).toISOString() : null);

export function stateFromElection(e: Election): WizardState {
  return { title: e.title, description: e.description ?? "", votingMethod: e.voting_method, seats: String(e.seats),
    threshold: e.threshold_percent ? String(e.threshold_percent) : "", access: e.access,
    opensAt: toLocalInput(e.opens_at), closesAt: toLocalInput(e.closes_at) };
}

export function validateStep(step: number, s: WizardState, methods: VotingMethod[], now = new Date()): WizardErrors {
  const e: WizardErrors = {};
  if (step === 0) {
    if (s.title.trim().length < 3) e.title = "Enter a title of at least 3 characters";
    else if (s.title.trim().length > 120) e.title = "Keep the title under 120 characters";
    if (s.description.length > 2000) e.description = "Keep the description under 2,000 characters";
  }
  if (step === 1) {
    const method = methods.find((m) => m.key === s.votingMethod);
    if (!method) e.votingMethod = "Choose a voting system";
    const seats = Number(s.seats);
    if (!Number.isInteger(seats) || seats < 1 || seats > 100) e.seats = "Enter a whole number of seats from 1 to 100";
    else if (method?.max_seats != null && seats > method.max_seats) e.seats = `${method.name} elects exactly ${method.max_seats} ${method.max_seats === 1 ? "seat" : "seats"}`;
    if (method?.supports_threshold && s.threshold.trim() !== "") {
      const t = Number(s.threshold);
      if (!Number.isFinite(t) || t < 0 || t > 100) e.threshold = "Enter a percentage from 0 to 100";
    }
  }
  if (step === 2) {
    const opens = s.opensAt ? new Date(s.opensAt) : null;
    const closes = s.closesAt ? new Date(s.closesAt) : null;
    if (opens && closes && closes <= opens) e.closesAt = "Closing time must be after the opening time";
    if (opens && opens <= now) e.opensAt = "Opening time must be in the future";
    if (!opens && closes) e.opensAt = "Set an opening time as well";
    if (opens && !closes) e.closesAt = "Set a closing time as well";
  }
  return e;
}

export function toInput(s: WizardState, methods: VotingMethod[]): ElectionInput {
  const method = methods.find((m) => m.key === s.votingMethod);
  return {
    title: s.title.trim(), description: s.description.trim() || null, voting_method: s.votingMethod, seats: Number(s.seats), access: s.access,
    opens_at: fromLocalInput(s.opensAt), closes_at: fromLocalInput(s.closesAt),
    threshold_percent: method?.supports_threshold && s.threshold.trim() !== "" ? Number(s.threshold) : null,
  };
}
