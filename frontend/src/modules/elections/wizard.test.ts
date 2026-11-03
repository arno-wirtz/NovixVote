import { describe, expect, it } from "vitest";
import type { VotingMethod } from "../../types/api";
import { emptyState, fromLocalInput, toInput, toLocalInput, validateStep } from "./wizard";

const methods: VotingMethod[] = [
  { key: "plurality", name: "Plurality", description: "", category: "plurality", ballot_type: "candidate", supports_threshold: false, max_seats: null },
  { key: "d_hondt", name: "D'Hondt", description: "", category: "proportional", ballot_type: "party_list", supports_threshold: true, max_seats: null },
  { key: "irv", name: "Instant-runoff", description: "", category: "majority", ballot_type: "ranked", supports_threshold: false, max_seats: 1 },
];
const NOW = new Date("2026-11-02T10:00:00");

describe("wizard validation", () => {
  it("step 0: title rules", () => {
    expect(validateStep(0, { ...emptyState(), title: "ab" }, methods)).toHaveProperty("title");
    expect(validateStep(0, { ...emptyState(), title: "  Board 2026 " }, methods)).toEqual({});
  });
  it("step 1: method, seats and threshold", () => {
    const base = { ...emptyState(), votingMethod: "d_hondt" };
    expect(validateStep(1, emptyState(), methods)).toHaveProperty("votingMethod");
    expect(validateStep(1, { ...base, seats: "0" }, methods)).toHaveProperty("seats");
    expect(validateStep(1, { ...base, seats: "2.5" }, methods)).toHaveProperty("seats");
    expect(validateStep(1, { ...base, seats: "9", threshold: "101" }, methods)).toHaveProperty("threshold");
    expect(validateStep(1, { ...base, seats: "9", threshold: "5" }, methods)).toEqual({});
    // threshold is ignored for methods that don't support it
    expect(validateStep(1, { ...emptyState(), votingMethod: "plurality", threshold: "999" }, methods)).toEqual({});
  });
  it("step 1: single-winner methods allow exactly one seat", () => {
    const irv = { ...emptyState(), votingMethod: "irv" };
    expect(validateStep(1, { ...irv, seats: "1" }, methods)).toEqual({});
    expect(validateStep(1, { ...irv, seats: "3" }, methods).seats).toMatch(/exactly 1 seat/);
  });
  it("step 2: schedule is optional but must be coherent", () => {
    expect(validateStep(2, emptyState(), methods, NOW)).toEqual({});
    expect(validateStep(2, { ...emptyState(), opensAt: "2026-11-03T09:00", closesAt: "2026-11-03T08:00" }, methods, NOW)).toHaveProperty("closesAt");
    expect(validateStep(2, { ...emptyState(), opensAt: "2026-11-01T09:00", closesAt: "2026-11-03T09:00" }, methods, NOW)).toHaveProperty("opensAt");
    expect(validateStep(2, { ...emptyState(), opensAt: "2026-11-03T09:00" }, methods, NOW)).toHaveProperty("closesAt");
    expect(validateStep(2, { ...emptyState(), opensAt: "2026-11-03T09:00", closesAt: "2026-11-04T09:00" }, methods, NOW)).toEqual({});
  });
  it("builds the API payload", () => {
    const s = { ...emptyState(), title: " Council ", votingMethod: "d_hondt", seats: "9", threshold: "5", description: " " };
    expect(toInput(s, methods)).toMatchObject({ title: "Council", description: null, seats: 9, threshold_percent: 5, opens_at: null });
    expect(toInput({ ...s, votingMethod: "plurality" }, methods).threshold_percent).toBeNull();
  });
  it("round-trips local datetime values", () => {
    const iso = fromLocalInput("2026-11-03T09:30")!;
    expect(toLocalInput(iso)).toBe("2026-11-03T09:30");
    expect(fromLocalInput("")).toBeNull();
    expect(toLocalInput(null)).toBe("");
  });
});
