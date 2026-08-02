import type { Env } from "./types";

export const MIN_ADMIN_SECRET_BYTES = 32;

const KNOWN_PLACEHOLDERS = new Set([
  "changeme",
  "change-me",
  "dev-key-1",
  "replace-me",
  "replace_with_secret",
  "secret",
]);

export function isSecureAdminSecret(value: string | undefined): value is string {
  if (!value) return false;
  const trimmed = value.trim();
  if (!trimmed || trimmed !== value) return false;
  const normalized = trimmed.toLowerCase();
  if (KNOWN_PLACEHOLDERS.has(normalized)) return false;
  if (new TextEncoder().encode(value).byteLength < MIN_ADMIN_SECRET_BYTES) return false;
  return new Set(value).size >= 8;
}

export function configuredAdminApiTokens(env: Env): string[] {
  return (env.API_KEYS ?? "")
    .split(",")
    .map((value) => value.trim())
    .filter(Boolean);
}

export function adminApiTokensAreSecure(env: Env): boolean {
  const tokens = configuredAdminApiTokens(env);
  return tokens.length > 0 && tokens.every(isSecureAdminSecret);
}
