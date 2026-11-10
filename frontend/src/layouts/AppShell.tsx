import { useEffect, useState } from "react";
import { NavLink, Outlet, useLocation } from "react-router-dom";
import { useAuth } from "../app/providers/AuthProvider";
import { Button } from "../components/ui/ui";
import { Logo } from "../components/ui/Logo";
import { ThemeToggle } from "../components/ui/ThemeToggle";

const NAV = [{ to: "/dashboard", label: "Dashboard" }, { to: "/workspaces", label: "Workspaces" }];

export function AppShell() {
  const { session, signOut } = useAuth();
  const [open, setOpen] = useState(false);
  const { pathname } = useLocation();
  useEffect(() => setOpen(false), [pathname]);
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && setOpen(false);
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  return (
    <div className="shell">
      <a href="#main" className="skip-link">Skip to content</a>
      <header className="topbar">
        <button type="button" className="btn btn-secondary menu-btn" aria-expanded={open} aria-controls="sidebar" onClick={() => setOpen((o) => !o)}>
          Menu
        </button>
        <Logo />
        <div className="topbar-end"><ThemeToggle /></div>
      </header>
      <aside id="sidebar" className={`sidebar ${open ? "is-open" : ""}`} aria-label="Primary">
        <div className="sidebar-logo"><Logo /></div>
        <nav>
          {NAV.map((n) => <NavLink key={n.to} to={n.to} className={({ isActive }) => `nav-link ${isActive ? "is-active" : ""}`}>{n.label}</NavLink>)}
        </nav>
        <div className="sidebar-foot">
          <p className="muted small" title={session?.user.email ?? ""}>{session?.user.email}</p>
          <Button variant="secondary" onClick={() => void signOut()}>Sign out</Button>
        </div>
      </aside>
      {open && <button type="button" className="scrim" aria-label="Close menu" onClick={() => setOpen(false)} />}
      <main id="main" className="main" tabIndex={-1}><div className="page-container"><Outlet /></div></main>
    </div>
  );
}
