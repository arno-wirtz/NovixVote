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

// ---- results and audit (phase 6) ----
export interface CountResult {
  method: string; category: string; ballot_type: string; seats: number; candidates: string[];
  tallies: Record<string, number>; winners: string[]; allocations: Record<string, number>; below_threshold: string[];
  valid_ballots: number; blank_ballots: number; invalid_ballots: number; invalid_reasons: Record<string, number>;
  allocation_log: { seat: number; list: string; votes: number; divisor: number; quotient: string }[];
  rounds: { round: number; tallies: Record<string, number>; exhausted: number; active: number; eliminated: string[]; winner: string | null; tie_resolution: string | null }[];
  tied_for_last_seat: string[]; unallocated_seats: number; tie_resolution: Record<string, unknown> | null; complete: boolean;
}
export interface TieBreakInput { method: "lots" | "agreed_order" | "other"; note: string; order: string[] }
export interface TieBreakRecord extends TieBreakInput { [key: string]: unknown }
export interface TallyRun {
  id: string; run_number: number; created_at: string; input_hash: string; ballot_count: number;
  tie_break: TieBreakRecord | null; result: CountResult; approved: boolean; approved_at: string | null;
}
export interface PublishedResult {
  ballot_count: number; run_number: number | null; approved_at: string | null; input_hash: string | null;
  tie_break: TieBreakRecord | null; result: CountResult | null;
}
export interface AuditEvent { id: number; event_type: string; entity_type: string | null; entity_id: string | null; actor_id: string | null; metadata: Record<string, unknown>; created_at: string; hash: string }
export interface AuditVerify { ok: boolean; checked: number; first_bad_id: number | null }
