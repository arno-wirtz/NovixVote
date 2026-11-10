import { useCallback, useEffect, useState, type FormEvent } from "react";
import { useAuth } from "../../app/providers/AuthProvider";
import { Alert, Button, Card, Field, SelectField, StatusBadge } from "../../components/ui/ui";
import { ApiError } from "../../services/api";
import type { Invitation, Member, OrgRole } from "../../types/api";
import { useOrgContext } from "../organisations/useOrgContext";
import { ROLE_HELP, ROLE_LABEL, assignableRoles, canManageMember, invitableRoles } from "../organisations/roles";

const errMsg = (e: unknown, fallback: string) => (e instanceof ApiError ? e.message : fallback);

export function MembersPage() {
  const { orgId, membership, can } = useOrgContext();
  const { api, session } = useAuth();
  const me = session?.user.id;
  const actor = membership.role;
  const [members, setMembers] = useState<Member[] | null>(null);
  const [invites, setInvites] = useState<Invitation[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [confirming, setConfirming] = useState<string | null>(null);
  const [email, setEmail] = useState("");
  const [role, setRole] = useState<OrgRole>("voter");
  const [emailError, setEmailError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const manage = can("members.manage");

  const load = useCallback(async () => {
    try {
      setMembers(await api.members(orgId));
      setInvites(manage ? await api.invitations(orgId) : []);
    } catch (e) { setError(errMsg(e, "Couldn't load members")); }
  }, [api, orgId, manage]);
  useEffect(() => { void load(); }, [load]);

  async function run(action: () => Promise<unknown>, success?: string) {
    setError(null); setNotice(null); setBusy(true);
    try { await action(); if (success) setNotice(success); await load(); }
    catch (e) { setError(errMsg(e, "Something went wrong")); }
    finally { setBusy(false); setConfirming(null); }
  }

  async function onInvite(e: FormEvent) {
    e.preventDefault();
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email.trim())) { setEmailError("Enter a valid email address"); return; }
    setEmailError(null);
    await run(async () => { await api.invite(orgId, email.trim(), role); setEmail(""); }, "Invitation sent. They'll see it after signing in with that email address.");
  }

  return (
    <>
      {error && <Alert tone="danger">{error}</Alert>}
      {notice && <Alert tone="success">{notice}</Alert>}
      <div className="grid-2 grid-top">
        <Card title="Members">
          {!members && <p className="muted" role="status">Loading…</p>}
          <ul className="list">
            {members?.map((m) => {
              const self = m.user_id === me;
              const editable = !self && canManageMember(actor, m.role) && manage;
              return (
                <li key={m.user_id}>
                  <div><strong>{m.display_name || m.email || "Member"}{self ? " (you)" : ""}</strong>
                    {m.display_name && <span className="muted small">{m.email}</span>}</div>
                  <span className="row-actions">
                    {editable ? (
                      <SelectField label={`Role for ${m.email ?? "member"}`} value={m.role} disabled={busy}
                        onChange={(e) => void run(() => api.changeRole(orgId, m.user_id, e.target.value as OrgRole), "Role updated")}>
                        {assignableRoles(actor).map((r) => <option key={r} value={r}>{ROLE_LABEL[r]}</option>)}
                      </SelectField>
                    ) : <StatusBadge tone="info">{ROLE_LABEL[m.role]}</StatusBadge>}
                    {(editable || self) && (confirming === m.user_id ? (
                      <>
                        <Button variant="danger" loading={busy} onClick={() => void run(() => api.removeMember(orgId, m.user_id), self ? "You left the workspace" : "Member removed")}>
                          {self ? "Leave" : "Remove"}
                        </Button>
                        <Button variant="secondary" onClick={() => setConfirming(null)}>Cancel</Button>
                      </>
                    ) : <Button variant="secondary" onClick={() => setConfirming(m.user_id)}>{self ? "Leave workspace" : "Remove"}</Button>)}
                  </span>
                </li>
              );
            })}
          </ul>
          {members && !manage && <p className="muted small">Only owners and administrators can change members.</p>}
        </Card>

        {manage && (
          <div>
            <Card title="Invite someone">
              <form onSubmit={onInvite} noValidate>
                <Field label="Email address" type="email" autoComplete="off" value={email} onChange={(e) => setEmail(e.target.value)} error={emailError} />
                <SelectField label="Role" value={role} onChange={(e) => setRole(e.target.value as OrgRole)} hint={ROLE_HELP[role]}>
                  {invitableRoles(actor).map((r) => <option key={r} value={r}>{ROLE_LABEL[r]}</option>)}
                </SelectField>
                <Button type="submit" loading={busy}>Send invitation</Button>
              </form>
              <p className="muted small">Invitations expire after 14 days. The person must sign in with this exact, confirmed email address to accept.</p>
            </Card>
            <Card title="Pending invitations">
              {invites.length === 0 && <p className="muted">No pending invitations.</p>}
              <ul className="list">
                {invites.map((i) => (
                  <li key={i.id}>
                    <div><strong>{i.email}</strong><span className="muted small">{ROLE_LABEL[i.role]}</span></div>
                    {canManageMember(actor, i.role) && <Button variant="secondary" disabled={busy} onClick={() => void run(() => api.revokeInvitation(i.id), "Invitation revoked")}>Revoke</Button>}
                  </li>
                ))}
              </ul>
            </Card>
          </div>
        )}
      </div>
    </>
  );
}
