export interface Health { status: string; service: string; version: string; environment: string; supabase_configured: boolean; time: string }
export type OrgRole = "owner" | "admin" | "election_manager" | "voter";
export interface Organisation { id: string; name: string; slug: string; role: OrgRole }
export interface Membership { role: OrgRole; permissions: string[] }
export interface Member { user_id: string; email: string | null; display_name: string | null; role: OrgRole; status: string; joined_at: string }
export interface Invitation { id: string; organisation_id: string; email: string; role: OrgRole; status: string; expires_at: string; created_at: string }
export interface MyInvitation { id: string; organisation_id: string; organisation_name: string; role: OrgRole; expires_at: string; created_at: string }
export interface VotingMethod { key: string; name: string; description: string; category: string; ballot_type: string; supports_threshold: boolean; max_seats: number | null }
export type ElectionStatus = "draft" | "scheduled" | "open" | "closed" | "published";
export type ElectionAccess = "restricted" | "public";
export interface Election {
  id: string; organisation_id: string; title: string; description: string | null; voting_method: string; seats: number;
  access: ElectionAccess; status: ElectionStatus; opens_at: string | null; closes_at: string | null;
  threshold_percent: number | null; allow_vote_change: boolean; allow_blank_ballot: boolean;
  published_at: string | null; created_at: string; updated_at: string; organisation_name?: string | null;
}
export interface ElectionInput {
  title: string; description: string | null; voting_method: string; seats: number; access: ElectionAccess;
  opens_at: string | null; closes_at: string | null; threshold_percent: number | null;
  allow_vote_change: boolean; allow_blank_ballot: boolean;
}

export interface BallotOption { id: string; election_id: string; label: string; description: string | null; members: string[]; sort_order: number }
export interface BallotOptionInput { label: string; description: string | null; members: string[] }
export interface VoterRow { email: string; name?: string | null }
export interface Voter { id: string; email: string; name: string | null; created_at: string }
export interface VoterPage { total: number; all_total: number; items: Voter[] }
export interface VotersResult { added: number; duplicates: number; invalid_count: number; invalid: { row: number; email: string; reason: string }[]; total: number }
export interface ReadinessItem { key: string; ok: boolean; label: string; problem: string }
export interface MyElection { id: string; organisation_name: string; title: string; status: ElectionStatus; opens_at: string | null; closes_at: string | null }

// ---- voting (phase 5) ----
export interface VoteReceipt { receipt: string; changed: boolean }
export interface MyVote { voted: boolean; can_change: boolean; selections: string[] | null }
export interface Turnout { voted: number; eligible: number | null }
