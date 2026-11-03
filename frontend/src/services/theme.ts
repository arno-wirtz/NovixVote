export type ThemePreference = "light" | "dark" | "system";
export type ResolvedTheme = "light" | "dark";
export const THEME_KEY = "novixvote-theme";

export function resolveTheme(pref: ThemePreference, systemPrefersDark: boolean): ResolvedTheme {
  if (pref === "system") return systemPrefersDark ? "dark" : "light";
  return pref;
}

export function readPreference(storage: Pick<Storage, "getItem"> = localStorage): ThemePreference {
  try {
    const v = storage.getItem(THEME_KEY);
    return v === "light" || v === "dark" || v === "system" ? v : "system";
  } catch { return "system"; }
}

export function savePreference(pref: ThemePreference, storage: Pick<Storage, "setItem"> = localStorage): void {
  try { storage.setItem(THEME_KEY, pref); } catch { /* storage unavailable: preference lasts for this session only */ }
}
