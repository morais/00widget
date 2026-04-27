import type { Env } from "./types";

export interface AuthContext {
  apiKey: string;
  apiKeyHash: string;
}

export async function requireAuth(req: Request, env: Env): Promise<AuthContext> {
  const header = req.headers.get("authorization") ?? "";
  const match = /^Bearer\s+(.+)$/i.exec(header);
  if (!match) {
    throw new AuthError("missing or malformed Authorization header");
  }
  const provided = match[1].trim();
  const allowed = (env.API_KEYS ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  if (allowed.length === 0) {
    throw new AuthError("server has no API_KEYS configured");
  }
  const ok = allowed.some((k) => constantTimeEqual(k, provided));
  if (!ok) {
    throw new AuthError("invalid API key");
  }
  return {
    apiKey: provided,
    apiKeyHash: await sha256Hex(provided),
  };
}

export class AuthError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "AuthError";
  }
}

/// Validates an API key against the comma-separated `API_KEYS` env var.
/// Used by the admin dashboard's API-token login path, which receives the
/// key in a form body rather than an Authorization header.
export function isValidApiKey(env: Env, provided: string): boolean {
  const trimmed = provided.trim();
  if (!trimmed) return false;
  const allowed = (env.API_KEYS ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  if (allowed.length === 0) return false;
  return allowed.some((k) => constantTimeEqual(k, trimmed));
}

function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}

export async function sha256Hex(input: string): Promise<string> {
  const data = new TextEncoder().encode(input);
  const digest = await crypto.subtle.digest("SHA-256", data);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
