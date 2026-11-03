import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from "react";
import { readPreference, resolveTheme, savePreference, type ResolvedTheme, type ThemePreference } from "../../services/theme";

interface ThemeCtx { preference: ThemePreference; resolved: ResolvedTheme; setPreference: (p: ThemePreference) => void }
const Ctx = createContext<ThemeCtx | null>(null);
const query = () => window.matchMedia("(prefers-color-scheme: dark)");

export function ThemeProvider({ children }: { children: ReactNode }) {
  const [preference, setPref] = useState<ThemePreference>(() => readPreference());
  const [systemDark, setSystemDark] = useState(() => query().matches);
  const resolved = resolveTheme(preference, systemDark);

  useEffect(() => {
    const mq = query();
    const on = (e: MediaQueryListEvent) => setSystemDark(e.matches);
    mq.addEventListener("change", on);
    return () => mq.removeEventListener("change", on);
  }, []);
  useEffect(() => { document.documentElement.dataset.theme = resolved; }, [resolved]);

  const setPreference = useCallback((p: ThemePreference) => { setPref(p); savePreference(p); }, []);
  const value = useMemo(() => ({ preference, resolved, setPreference }), [preference, resolved, setPreference]);
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useTheme(): ThemeCtx {
  const v = useContext(Ctx);
  if (!v) throw new Error("useTheme must be used inside ThemeProvider");
  return v;
}
