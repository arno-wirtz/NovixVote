import { describe, expect, it, vi } from "vitest";
import { ApiError, createApi } from "./api";

const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status });

describe("api client", () => {
  it("sends the bearer token on authenticated calls", async () => {
    const f = vi.fn().mockResolvedValue(json(200, []));
    await createApi(async () => "tok", f as unknown as typeof fetch).organisations();
    expect((f.mock.calls[0][1].headers as Headers).get("Authorization")).toBe("Bearer tok");
  });
  it("does not send credentials to the public health endpoint", async () => {
    const f = vi.fn().mockResolvedValue(json(200, { status: "ok" }));
    await createApi(async () => "tok", f as unknown as typeof fetch).health();
    expect((f.mock.calls[0][1].headers as Headers).has("Authorization")).toBe(false);
  });
  it("refuses to call without a session", async () => {
    const f = vi.fn();
    await expect(createApi(async () => null, f as unknown as typeof fetch).organisations()).rejects.toMatchObject({ status: 401 });
    expect(f).not.toHaveBeenCalled();
  });
  it("surfaces server messages and network failures", async () => {
    const api = createApi(async () => "t", vi.fn().mockResolvedValue(json(409, { detail: "That workspace address is already taken" })) as unknown as typeof fetch);
    await expect(api.createOrganisation("A b")).rejects.toThrow("already taken");
    const down = createApi(async () => "t", vi.fn().mockRejectedValue(new TypeError("x")) as unknown as typeof fetch);
    await expect(down.organisations()).rejects.toBeInstanceOf(ApiError);
  });
});
