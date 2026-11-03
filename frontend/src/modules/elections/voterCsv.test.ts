import { describe, expect, it } from "vitest";
import { MAX_UPLOAD_ROWS, chunk, parseVoterText } from "./voterCsv";

describe("voter upload parsing", () => {
  it("accepts plain emails, optional names and a header", () => {
    const r = parseVoterText("Email,Name\nAna@Example.com,Ana Diaz\nben@example.com\n\n  cara@example.com ; ignored");
    expect(r.rows).toEqual([{ email: "ana@example.com", name: "Ana Diaz" }, { email: "ben@example.com", name: null }, { email: "cara@example.com", name: "ignored" }]);
    expect(r.problems).toEqual([]);
  });
  it("handles BOM, CRLF, semicolons, tabs and quoted names containing commas", () => {
    const r = parseVoterText('\uFEFFe-mail;name\r\na@x.io;"Smith, Jo"\r\nb@x.io\tBob\r\n"c@x.io","Say ""hi"""');
    expect(r.rows.map((v) => v.name)).toEqual(["Smith, Jo", "Bob", 'Say "hi"']);
  });
  it("reports bad rows with line numbers and dedupes case-insensitively", () => {
    const r = parseVoterText("a@x.io\nnot-an-email\nA@X.IO\n@x.io\nb@x.io,Name\n");
    expect(r.rows.map((v) => v.email)).toEqual(["a@x.io", "b@x.io"]);
    expect(r.duplicates).toBe(1);
    expect(r.problems.map((p) => p.line)).toEqual([2, 4]);
  });
  it("does not treat the first row as a header unless it says email", () => {
    expect(parseVoterText("a@x.io").rows).toHaveLength(1);
    expect(parseVoterText("name,email\nAna,a@x.io").rows).toEqual([]);   // wrong column order is reported, not guessed
  });
  it("rejects over-long names and caps the number of rows", () => {
    expect(parseVoterText(`a@x.io,${"n".repeat(121)}`).problems[0].reason).toMatch(/120/);
    const big = Array.from({ length: MAX_UPLOAD_ROWS + 5 }, (_, i) => `u${i}@x.io`).join("\n");
    const r = parseVoterText(big);
    expect(r.rows).toHaveLength(MAX_UPLOAD_ROWS);
    expect(r.problems.at(-1)?.reason).toBe("Too many rows");
  });
  it("chunks uploads for the API limit", () => {
    expect(chunk([1, 2, 3, 4, 5], 2)).toEqual([[1, 2], [3, 4], [5]]);
    expect(chunk([], 1000)).toEqual([]);
  });
});
