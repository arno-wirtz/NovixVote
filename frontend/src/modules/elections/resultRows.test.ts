import { describe, expect, it } from "vitest";
import type { CountResult } from "../../types/api";
import { resultRows } from "./resultRows";

const base: CountResult = {
  method: "plurality", category: "plurality", ballot_type: "candidate", seats: 1, candidates: ["Ana", "Ben", "Cara"],
  tallies: { Ana: 2, Ben: 5, Cara: 5 }, winners: ["Ben"], allocations: {}, below_threshold: [], valid_ballots: 12, blank_ballots: 1, invalid_ballots: 0,
  invalid_reasons: {}, allocation_log: [], rounds: [], tied_for_last_seat: [], unallocated_seats: 0, tie_resolution: null, complete: true,
};

describe("resultRows", () => {
  it("sorts by votes, keeps ballot order for ties, and computes shares of valid ballots", () => {
    const rows = resultRows(base);
    expect(rows.map((r) => r.name)).toEqual(["Ben", "Cara", "Ana"]);
    expect(rows[0]).toMatchObject({ votes: 5, share: 41.7, seats: null, elected: true });
    expect(rows[1].elected).toBe(false);
  });
  it("shows seats for proportional methods and no share when there are no valid ballots", () => {
    const rows = resultRows({ ...base, category: "proportional", allocations: { Ana: 1 }, winners: ["Ana"] });
    expect(rows.find((r) => r.name === "Ana")?.seats).toBe(1);
    expect(rows.find((r) => r.name === "Ben")?.seats).toBe(0);
    expect(resultRows({ ...base, valid_ballots: 0, tallies: {} })[0].share).toBeNull();
  });
});
