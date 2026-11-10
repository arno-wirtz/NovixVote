import { describe, expect, it } from "vitest";
import { rankingToSelection, selectionToRanks, validateSelection } from "./voteRules";

describe("vote rules (mirror of cast_vote)", () => {
  it("requires at least one selection unless blank ballots are allowed", () => {
    expect(validateSelection("candidate", 1, [], false)).toMatch(/at least one/);
    expect(validateSelection("candidate", 1, [], true)).toBeNull();
  });
  it("enforces seat and list limits and duplicates", () => {
    expect(validateSelection("candidate", 2, ["a", "b", "c"], false)).toMatch(/at most 2 candidates/);
    expect(validateSelection("candidate", 1, ["a", "b"], false)).toMatch(/at most 1 candidate$/);
    expect(validateSelection("party_list", 5, ["a", "b"], false)).toBe("Choose one list");
    expect(validateSelection("ranked", 1, ["a", "b", "c"], false)).toBeNull();
    expect(validateSelection("candidate", 3, ["a", "a"], false)).toMatch(/same option twice/);
  });
  it("turns ranks into an ordered selection and rejects repeated ranks", () => {
    expect(rankingToSelection({ a: "2", b: "1", c: "" })).toEqual({ selection: ["b", "a"], error: null });
    expect(rankingToSelection({ a: "1", b: "1" }).error).toMatch(/once/);
    expect(rankingToSelection({ a: "", b: "" })).toEqual({ selection: [], error: null });
  });
  it("round-trips ranks", () => {
    expect(rankingToSelection(selectionToRanks(["x", "y", "z"])).selection).toEqual(["x", "y", "z"]);
  });
});
