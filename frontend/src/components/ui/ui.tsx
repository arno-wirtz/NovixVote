import { forwardRef, useId, type ButtonHTMLAttributes, type InputHTMLAttributes, type ReactNode } from "react";

type Variant = "primary" | "secondary" | "danger";
interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> { variant?: Variant; loading?: boolean }

export const Button = forwardRef<HTMLButtonElement, ButtonProps>(function Button(
  { variant = "primary", loading, disabled, children, className = "", ...rest }, ref) {
  return (
    <button ref={ref} className={`btn btn-${variant} ${className}`} disabled={disabled || loading} aria-busy={loading || undefined} {...rest}>
      {loading ? "Working…" : children}
    </button>
  );
});

interface FieldProps extends InputHTMLAttributes<HTMLInputElement> { label: string; error?: string | null; hint?: string }
export function Field({ label, error, hint, id, ...rest }: FieldProps) {
  const auto = useId();
  const fid = id ?? auto;
  const describedBy = [error ? `${fid}-err` : null, hint ? `${fid}-hint` : null].filter(Boolean).join(" ") || undefined;
  return (
    <div className="field">
      <label htmlFor={fid}>{label}</label>
      <input id={fid} aria-invalid={error ? true : undefined} aria-describedby={describedBy} {...rest} />
      {hint && <p id={`${fid}-hint`} className="hint">{hint}</p>}
      {error && <p id={`${fid}-err`} className="field-error" role="alert">{error}</p>}
    </div>
  );
}

export function Card({ title, children, action }: { title?: string; children: ReactNode; action?: ReactNode }) {
  return (
    <section className="card">
      {(title || action) && <header className="card-head">{title && <h2>{title}</h2>}{action}</header>}
      {children}
    </section>
  );
}

type Tone = "success" | "danger" | "info" | "neutral";
const ICON: Record<Tone, string> = { success: "✓", danger: "!", info: "i", neutral: "–" };
export function StatusBadge({ tone, children }: { tone: Tone; children: ReactNode }) {
  return <span className={`badge badge-${tone}`}><span aria-hidden="true">{ICON[tone]}</span> {children}</span>;
}

export function Alert({ tone, children }: { tone: "danger" | "info" | "success"; children: ReactNode }) {
  return <div className={`alert alert-${tone}`} role={tone === "danger" ? "alert" : "status"}>{children}</div>;
}

import type { SelectHTMLAttributes, TextareaHTMLAttributes } from "react";

export function SelectField({ label, error, hint, id, children, ...rest }: SelectHTMLAttributes<HTMLSelectElement> & { label: string; error?: string | null; hint?: string }) {
  const auto = useId();
  const fid = id ?? auto;
  return (
    <div className="field">
      <label htmlFor={fid}>{label}</label>
      <select id={fid} aria-invalid={error ? true : undefined} aria-describedby={error ? `${fid}-err` : hint ? `${fid}-hint` : undefined} {...rest}>{children}</select>
      {hint && !error && <p id={`${fid}-hint`} className="hint">{hint}</p>}
      {error && <p id={`${fid}-err`} className="field-error" role="alert">{error}</p>}
    </div>
  );
}

export function TextAreaField({ label, error, hint, id, ...rest }: TextareaHTMLAttributes<HTMLTextAreaElement> & { label: string; error?: string | null; hint?: string }) {
  const auto = useId();
  const fid = id ?? auto;
  return (
    <div className="field">
      <label htmlFor={fid}>{label}</label>
      <textarea id={fid} rows={4} aria-invalid={error ? true : undefined} aria-describedby={error ? `${fid}-err` : hint ? `${fid}-hint` : undefined} {...rest} />
      {hint && !error && <p id={`${fid}-hint`} className="hint">{hint}</p>}
      {error && <p id={`${fid}-err`} className="field-error" role="alert">{error}</p>}
    </div>
  );
}
