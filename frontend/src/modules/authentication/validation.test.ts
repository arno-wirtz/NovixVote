import { expect, it } from "vitest";
import { validateCredentials } from "./validation";

it("validates sign-in and sign-up rules", () => {
  expect(validateCredentials("a@b.co", "x", "signin")).toEqual({});
  expect(validateCredentials("nope", "", "signin")).toHaveProperty("email");
  expect(validateCredentials("a@b.co", "short", "signup")).toHaveProperty("password");
  expect(validateCredentials("a@b.co", "longenough1", "signup")).toEqual({});
});
