import { env } from "../app/configuration/env";
import type { BallotOption, BallotOptionInput, Election, ElectionInput, ElectionStatus, Health, Invitation, Member, Membership, MyElection, MyInvitation, OrgRole, Organisation, ReadinessItem, VoterPage, VoterRow, VotersResult, VotingMethod } from "../types/api";

export class ApiError extends Error {
  constructor(public status: number, message: string) { super(message); }
}

type TokenProvider = () => Promise<string | null>;

function messageFrom(body: unknown, fallback: string): string {
  const detail = (body as { detail?: unknown } | null)?.detail;
  if (typeof detail === "string") return detail;
  if (Array.isArray(detail) && detail[0]?.msg) return String(detail[0].msg).replace(/^Value error, /, "");
  return fallback;
}

export function createApi(getToken: TokenProvider, fetchImpl: typeof fetch = fetch) {
  async function request<T>(path: string, init: RequestInit = {}, authed = true): Promise<T> {
    const headers = new Headers(init.headers);
    if (init.body) headers.set("Content-Type", "application/json");
    if (authed) {
      const token = await getToken();
      if (!token) throw new ApiError(401, "You need to sign in");
      headers.set("Authorization", `Bearer ${token}`);
    }
    let res: Response;
    try { res = await fetchImpl(`${env.apiBaseUrl}/api/v1${path}`, { ...init, headers }); }
    catch { throw new ApiError(0, "Can't reach the NovixVote server"); }
    const body = await res.json().catch(() => null);
    if (!res.ok) throw new ApiError(res.status, messageFrom(body, "Something went wrong"));
    return body as T;
  }
  return {
    health: () => request<Health>("/health", {}, false),
    organisations: () => request<Organisation[]>("/organisations"),
    createOrganisation: (name: string, slug?: string) =>
      request<Organisation>("/organisations", { method: "POST", body: JSON.stringify({ name, slug: slug || undefined }) }),
    votingMethods: () => request<VotingMethod[]>("/voting-methods"),
    membership: (org: string) => request<Membership>(`/organisations/${org}/me`),
    members: (org: string) => request<Member[]>(`/organisations/${org}/members`),
    changeRole: (org: string, user: string, role: OrgRole) =>
      request<void>(`/organisations/${org}/members/${user}`, { method: "PATCH", body: JSON.stringify({ role }) }),
    removeMember: (org: string, user: string) => request<void>(`/organisations/${org}/members/${user}`, { method: "DELETE" }),
    invitations: (org: string) => request<Invitation[]>(`/organisations/${org}/invitations`),
    invite: (org: string, email: string, role: OrgRole) =>
      request<Invitation>(`/organisations/${org}/invitations`, { method: "POST", body: JSON.stringify({ email, role }) }),
    revokeInvitation: (id: string) => request<void>(`/invitations/${id}`, { method: "DELETE" }),
    myInvitations: () => request<MyInvitation[]>("/invitations/mine"),
    acceptInvitation: (id: string) => request<void>(`/invitations/${id}/accept`, { method: "POST" }),
    declineInvitation: (id: string) => request<void>(`/invitations/${id}/decline`, { method: "POST" }),
    elections: (org: string) => request<Election[]>(`/organisations/${org}/elections`),
    election: (id: string) => request<Election>(`/elections/${id}`),
    createElection: (org: string, input: ElectionInput) =>
      request<Election>(`/organisations/${org}/elections`, { method: "POST", body: JSON.stringify(input) }),
    updateElection: (id: string, input: ElectionInput) =>
      request<Election>(`/elections/${id}`, { method: "PUT", body: JSON.stringify(input) }),
    deleteElection: (id: string) => request<void>(`/elections/${id}`, { method: "DELETE" }),
    transitionElection: (id: string, to: ElectionStatus) =>
      request<Election>(`/elections/${id}/transition`, { method: "POST", body: JSON.stringify({ to }) }),
    myElections: () => request<MyElection[]>("/elections/mine"),
    ballot: (election: string) => request<BallotOption[]>(`/elections/${election}/ballot`),
    addOption: (election: string, input: BallotOptionInput) =>
      request<BallotOption>(`/elections/${election}/ballot/options`, { method: "POST", body: JSON.stringify(input) }),
    updateOption: (id: string, input: BallotOptionInput) =>
      request<BallotOption>(`/ballot/options/${id}`, { method: "PUT", body: JSON.stringify(input) }),
    deleteOption: (id: string) => request<void>(`/ballot/options/${id}`, { method: "DELETE" }),
    reorderOptions: (election: string, ids: string[]) =>
      request<void>(`/elections/${election}/ballot/order`, { method: "PUT", body: JSON.stringify({ ids }) }),
    voters: (election: string, params: { limit: number; offset: number; search?: string }) => {
      const q = new URLSearchParams({ limit: String(params.limit), offset: String(params.offset) });
      if (params.search) q.set("search", params.search);
      return request<VoterPage>(`/elections/${election}/voters?${q}`);
    },
    addVoters: (election: string, voters: VoterRow[]) =>
      request<VotersResult>(`/elections/${election}/voters`, { method: "POST", body: JSON.stringify({ voters }) }),
    removeVoter: (id: string) => request<void>(`/voters/${id}`, { method: "DELETE" }),
    readiness: (election: string) => request<ReadinessItem[]>(`/elections/${election}/readiness`),
    eligibility: (election: string) => request<{ eligible: boolean }>(`/elections/${election}/eligibility`),
  };
}
export type Api = ReturnType<typeof createApi>;
