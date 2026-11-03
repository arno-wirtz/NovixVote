import { describe, expect, it } from "vitest";
import { assignableRoles, canManageMember, invitableRoles } from "../organisations/roles";

describe("role rules (mirror of the database rules)", () => {
  it("owners can assign anything but only invite non-owners", () => {
    expect(assignableRoles("owner")).toContain("owner");
    expect(invitableRoles("owner")).toEqual(["admin", "election_manager", "voter"]);
  });
  it("admins are limited to managers and voters", () => {
    expect(assignableRoles("admin")).toEqual(["election_manager", "voter"]);
    expect(canManageMember("admin", "voter")).toBe(true);
    expect(canManageMember("admin", "admin")).toBe(false);
    expect(canManageMember("admin", "owner")).toBe(false);
  });
  it("managers and voters manage nobody", () => {
    for (const r of ["election_manager", "voter"] as const) {
      expect(assignableRoles(r)).toEqual([]);
      expect(canManageMember(r, "voter")).toBe(false);
    }
  });
});
