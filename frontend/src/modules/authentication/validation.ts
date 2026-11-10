const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
export function validateCredentials(email: string, password: string, mode: "signin" | "signup") {
  const errors: { email?: string; password?: string } = {};
  if (!EMAIL.test(email.trim())) errors.email = "Enter a valid email address";
  if (mode === "signup" ? password.length < 10 : password.length === 0)
    errors.password = mode === "signup" ? "Use at least 10 characters" : "Enter your password";
  return errors;
}
