import { describe, expect, it } from "vitest";
import { readPreference, resolveTheme, savePreference } from "./theme";

describe("theme", () => {
  it("resolves explicit and system preferences", () => {
    expect(resolveTheme("light", true)).toBe("light");
    expect(resolveTheme("dark", false)).toBe("dark");
    expect(resolveTheme("system", true)).toBe("dark");
    expect(resolveTheme("system", false)).toBe("light");
  });
  it("persists valid values and ignores garbage", () => {
    const store: Record<string, string> = {};
    savePreference("dark", { setItem: (k, v) => { store[k] = v; } });
    expect(readPreference({ getItem: (k) => store[k] ?? null })).toBe("dark");
    expect(readPreference({ getItem: () => "purple" })).toBe("system");
    expect(readPreference({ getItem: () => { throw new Error("blocked"); } })).toBe("system");
  });
});
