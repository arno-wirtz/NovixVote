import { describe, expect, it } from "vitest";
import { ACTIONS, STATUS_ORDER, availableActions } from "./lifecycle";

describe("election lifecycle", () => {
  it("only offers legal moves", () => {
    expect(ACTIONS.draft.map((a) => a.to)).toEqual(["scheduled"]);
    expect(ACTIONS.scheduled.map((a) => a.to)).toEqual(["open", "draft"]);
    expect(ACTIONS.open.map((a) => a.to)).toEqual(["closed"]);
    expect(ACTIONS.closed.map((a) => a.to)).toEqual(["published"]);
    expect(ACTIONS.published).toEqual([]);
    expect(STATUS_ORDER).toEqual(["draft", "scheduled", "open", "closed", "published"]);
  });
  it("hides actions the user lacks permission for", () => {
    expect(availableActions("closed", ["election.manage"])).toEqual([]);
    expect(availableActions("closed", ["results.approve"]).map((a) => a.to)).toEqual(["published"]);
    expect(availableActions("draft", [])).toEqual([]);
  });
});
