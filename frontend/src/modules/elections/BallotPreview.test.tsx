import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import type { BallotOption, VotingMethod } from "../../types/api";
import { BallotPreview } from "./BallotPreview";

const opts: BallotOption[] = [
  { id: "1", election_id: "e", label: "Greens", description: "Climate", members: ["Ann", "Bob"], sort_order: 1 },
  { id: "2", election_id: "e", label: "Reds", description: null, members: [], sort_order: 2 },
];
const method = (ballot_type: string): VotingMethod => ({ key: "k", name: "n", description: "", category: "c", ballot_type, supports_threshold: false, max_seats: null });

describe("BallotPreview", () => {
  it("shows lists as single-choice, disabled, with ordered candidates", () => {
    render(<BallotPreview options={opts} method={method("party_list")} seats={5} />);
    const radios = screen.getAllByRole("radio");
    expect(radios).toHaveLength(2);
    radios.forEach((r) => expect(r).toBeDisabled());
    expect(screen.getByText("Choose one list.")).toBeInTheDocument();
    expect(screen.getAllByRole("listitem").map((li) => li.textContent)).toEqual(expect.arrayContaining(["Ann", "Bob"]));
    expect(screen.getByText(/Preview only/)).toBeInTheDocument();
  });
  it("shows candidates as multi-choice up to the number of seats", () => {
    render(<BallotPreview options={opts} method={method("candidate")} seats={2} />);
    expect(screen.getAllByRole("checkbox")).toHaveLength(2);
    expect(screen.getByText(/Choose up to 2 candidates/)).toBeInTheDocument();
  });
  it("shows ranked ballots as disabled rank pickers", () => {
    render(<BallotPreview options={opts} method={method("ranked")} seats={1} />);
    const picks = screen.getAllByRole("combobox");
    expect(picks).toHaveLength(2);
    picks.forEach((p) => expect(p).toBeDisabled());
    expect(screen.getByLabelText("Rank for Greens")).toBeInTheDocument();
    expect(screen.getByText(/with 1 as your first choice/)).toBeInTheDocument();
  });
  it("says so when the ballot is empty", () => {
    render(<BallotPreview options={[]} method={undefined} seats={1} />);
    expect(screen.getByText("The ballot is empty.")).toBeInTheDocument();
  });
});
