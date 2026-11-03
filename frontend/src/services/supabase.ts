import { createClient } from "@supabase/supabase-js";
import { env, supabaseConfigured } from "../app/configuration/env";

// Placeholder values keep the module importable when unconfigured; the UI blocks sign-in in that case.
export const supabase = createClient(
  supabaseConfigured ? env.supabaseUrl : "http://localhost:54321",
  supabaseConfigured ? env.supabaseAnonKey : "unconfigured",
  { auth: { persistSession: true, autoRefreshToken: true } },
);
