import type { Session } from "@supabase/supabase-js";
import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from "react";
import { createApi, type Api } from "../../services/api";
import { supabase } from "../../services/supabase";

interface AuthCtx { session: Session | null; loading: boolean; api: Api; signOut: () => Promise<void> }
const Ctx = createContext<AuthCtx | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => { setSession(data.session); setLoading(false); })
      .catch(() => setLoading(false));
    const { data } = supabase.auth.onAuthStateChange((_e, s) => setSession(s));
    return () => data.subscription.unsubscribe();
  }, []);

  const api = useMemo(() => createApi(async () => (await supabase.auth.getSession()).data.session?.access_token ?? null), []);
  const value = useMemo(() => ({ session, loading, api, signOut: async () => { await supabase.auth.signOut(); } }), [session, loading, api]);
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useAuth(): AuthCtx {
  const v = useContext(Ctx);
  if (!v) throw new Error("useAuth must be used inside AuthProvider");
  return v;
}
