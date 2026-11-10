import { useCallback, useEffect, useState } from "react";
import { useAuth } from "../../app/providers/AuthProvider";
import { ApiError } from "../../services/api";
import type { Organisation } from "../../types/api";

export function useOrganisations() {
  const { api } = useAuth();
  const [items, setItems] = useState<Organisation[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  const reload = useCallback(async () => {
    try { setItems(await api.organisations()); setError(null); }
    catch (e) { setError(e instanceof ApiError ? e.message : "Could not load workspaces"); }
  }, [api]);
  useEffect(() => { void reload(); }, [reload]);
  return { items, error, reload };
}
