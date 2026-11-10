import type { OrgRole } from "../../types/api";

export const ROLE_LABEL: Record<OrgRole, string> = {
  owner: "Owner", admin: "Administrator", election_manager: "Election manager", voter: "Voter",
};
export const ROLE_HELP: Record<OrgRole, string> = {
  owner: "Full control, including results approval and ownership",
  admin: "Manages members and elections",
  election_manager: "Creates and runs elections",
  voter: "Takes part in elections they're eligible for",
};

const LOW: OrgRole[] = ["election_manager", "voter"];

/** Roles the actor may assign or invite. Mirrors can_manage_role() in the database; the server is the authority. */
export function assignableRoles(actor: OrgRole): OrgRole[] {
  if (actor === "owner") return ["owner", "admin", "election_manager", "voter"];
  if (actor === "admin") return LOW;
  return [];
}
export function invitableRoles(actor: OrgRole): OrgRole[] {
  return assignableRoles(actor).filter((r) => r !== "owner");
}
/** May the actor change or remove a member who currently holds `target`? */
export function canManageMember(actor: OrgRole, target: OrgRole): boolean {
  return actor === "owner" || (actor === "admin" && LOW.includes(target));
}
