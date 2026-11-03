import { describe, expect, it } from "vitest";
import { moveItem, parseMembers, validateOption } from "./ballot";

describe("ballot helpers", () => {
  it("parses one candidate per line", () => {
    expect(parseMembers(" Ann \r\n\r\nBob\n  \nCara ")).toEqual(["Ann", "Bob", "Cara"]);
    expect(parseMembers("")).toEqual([]);
  });
  it("validates options", () => {
    expect(validateOption("", "", [], false)).toHaveProperty("label");
    expect(validateOption("x".repeat(121), "", [], false)).toHaveProperty("label");
    expect(validateOption("Greens", "d".repeat(501), [], false)).toHaveProperty("description");
    expect(validateOption("Greens", "", ["Ann", "ann"], true)).toHaveProperty("members");
    expect(validateOption("Greens", "", ["Ann", "ann"], false)).toEqual({});          // members are ignored for candidate ballots
    expect(validateOption("Greens", "", ["Ann", "Bob"], true)).toEqual({});
  });
  it("moves items without leaving the list", () => {
    expect(moveItem(["a", "b", "c"], 1, -1)).toEqual(["b", "a", "c"]);
    expect(moveItem(["a", "b", "c"], 1, 1)).toEqual(["a", "c", "b"]);
    expect(moveItem(["a", "b", "c"], 0, -1)).toEqual(["a", "b", "c"]);
    expect(moveItem(["a", "b", "c"], 2, 1)).toEqual(["a", "b", "c"]);
  });
});
