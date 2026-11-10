import type { Election, ElectionStatus } from "../../types/api";

export const STATUS_ORDER: ElectionStatus[] = ["draft", "scheduled", "open", "closed", "published"];
export const STATUS_LABEL: Record<ElectionStatus, string> = {
  draft: "Draft", scheduled: "Scheduled", open: "Open for voting", closed: "Closed", published: "Published",
};
export const STATUS_TONE: Record<ElectionStatus, "neutral" | "info" | "success" | "danger"> = {
  draft: "neutral", scheduled: "info", open: "success", closed: "neutral", published: "success",
};
export const STATUS_HELP: Record<ElectionStatus, string> = {
  draft: "Only election managers can see this. Edit it freely, then schedule it.",
  scheduled: "Voting opens automatically at the opening time. Details are locked.",
  open: "Voting is under way. Details are locked.",
  closed: "Voting has ended. Waiting for results approval.",
  published: "Approved and visible to eligible members.",
};

export interface LifecycleAction { to: ElectionStatus; label: string; permission: string; tone: "primary" | "secondary" | "danger"; confirm?: string }

/** Legal manual moves per status. Mirrors transition_election() in the database; the server is the authority. */
export const ACTIONS: Record<ElectionStatus, LifecycleAction[]> = {
  draft: [{ to: "scheduled", label: "Schedule election", permission: "election.manage", tone: "primary" }],
  scheduled: [
    { to: "open", label: "Open voting now", permission: "election.manage", tone: "primary", confirm: "Open voting now? Voting will start immediately." },
    { to: "draft", label: "Move back to draft", permission: "election.manage", tone: "secondary" },
  ],
  open: [{ to: "closed", label: "Close voting now", permission: "election.manage", tone: "danger", confirm: "Close voting now? Nobody will be able to vote after this." }],
  closed: [{ to: "published", label: "Publish results", permission: "results.approve", tone: "primary", confirm: "Approve and publish? This can't be undone." }],
  published: [],
};

export function availableActions(status: ElectionStatus, permissions: string[]): LifecycleAction[] {
  return ACTIONS[status].filter((a) => permissions.includes(a.permission));
}
export const canEditOrDelete = (e: Election, permissions: string[]) => e.status === "draft" && permissions.includes("election.manage");

export function formatDateTime(iso: string | null): string {
  if (!iso) return "Not set";
  return new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(new Date(iso));
}
