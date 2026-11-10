import type { ReactNode } from "react";
import { Navigate } from "react-router-dom";
import { useAuth } from "../../app/providers/AuthProvider";

export function RequireAuth({ children }: { children: ReactNode }) {
  const { session, loading } = useAuth();
  if (loading) return <p className="center-note" role="status">Loading…</p>;
  if (!session) return <Navigate to="/login" replace />;
  return <>{children}</>;
}
