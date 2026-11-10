import { useState, type FormEvent } from "react";
import { Navigate } from "react-router-dom";
import { supabaseConfigured } from "../../app/configuration/env";
import { useAuth } from "../../app/providers/AuthProvider";
import { Alert, Button, Field } from "../../components/ui/ui";
import { Logo } from "../../components/ui/Logo";
import { ThemeToggle } from "../../components/ui/ThemeToggle";
import { supabase } from "../../services/supabase";
import { validateCredentials } from "./validation";

export function LoginPage() {
  const { session } = useAuth();
  const [mode, setMode] = useState<"signin" | "signup">("signin");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [errors, setErrors] = useState<{ email?: string; password?: string }>({});
  const [formError, setFormError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  if (session) return <Navigate to="/dashboard" replace />;

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    setFormError(null); setNotice(null);
    const v = validateCredentials(email, password, mode);
    setErrors(v);
    if (v.email || v.password) return;
    setBusy(true);
    const creds = { email: email.trim(), password };
    const { data, error } = mode === "signin" ? await supabase.auth.signInWithPassword(creds) : await supabase.auth.signUp(creds);
    setBusy(false);
    if (error) setFormError(mode === "signin" ? "Email or password is incorrect" : error.message);
    else if (mode === "signup" && !data.session) setNotice("Check your inbox to confirm your email, then sign in.");
  }

  return (
    <div className="auth-page">
      <div className="auth-top"><Logo /><ThemeToggle /></div>
      <div className="auth-card card">
        <h1>{mode === "signin" ? "Sign in to NovixVote" : "Create your account"}</h1>
        <p className="muted">Voting made simple. Effortless voting for everyone.</p>
        {!supabaseConfigured && <Alert tone="danger">Supabase isn't configured. Set VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY in frontend/.env.local.</Alert>}
        {formError && <Alert tone="danger">{formError}</Alert>}
        {notice && <Alert tone="success">{notice}</Alert>}
        <form onSubmit={onSubmit} noValidate>
          <Field label="Email address" type="email" autoComplete="email" value={email} onChange={(e) => setEmail(e.target.value)} error={errors.email} />
          <Field label="Password" type="password" autoComplete={mode === "signin" ? "current-password" : "new-password"}
            value={password} onChange={(e) => setPassword(e.target.value)} error={errors.password}
            hint={mode === "signup" ? "At least 10 characters" : undefined} />
          <Button type="submit" loading={busy} disabled={!supabaseConfigured}>{mode === "signin" ? "Sign in" : "Create account"}</Button>
        </form>
        <p className="small">
          {mode === "signin" ? "New to NovixVote? " : "Already have an account? "}
          <button type="button" className="link-btn" onClick={() => { setMode(mode === "signin" ? "signup" : "signin"); setErrors({}); setFormError(null); }}>
            {mode === "signin" ? "Create an account" : "Sign in"}
          </button>
        </p>
      </div>
    </div>
  );
}
