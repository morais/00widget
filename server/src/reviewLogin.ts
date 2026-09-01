import { AuthError, AuthRateLimitError } from "./auth";
import { issueAppCredentialBundle } from "./appCredentials";
import { parseJson } from "./cards";
import { json } from "./http";
import {
  authenticateReviewAccessCode,
  reviewLoginEnabled,
} from "./reviewAuth";
import { FieldLimits, RequestBodyLimits, type Env } from "./types";

interface ReviewTokenRequest {
  accessCode?: string;
  label?: string;
  deviceId?: string;
  issuePublisherCredential?: boolean;
}

export function handleReviewLoginConfig(_req: Request, env: Env): Response {
  return json(
    { enabled: reviewLoginEnabled(env) },
    200,
    { "cache-control": "no-store" },
  );
}

export async function createTokenFromReviewAccessCode(
  req: Request,
  env: Env,
): Promise<Response> {
  if (!reviewLoginEnabled(env)) return json({ error: "not found" }, 404);

  let input: ReviewTokenRequest;
  try {
    input = (await parseJson(req, RequestBodyLimits.reviewLogin)) as ReviewTokenRequest;
  } catch {
    return json({ error: "missing JSON body" }, 400);
  }
  if (!input || typeof input !== "object") return json({ error: "missing JSON body" }, 400);

  const accessCode = input.accessCode?.trim();
  if (!accessCode) return json({ error: "accessCode is required" }, 400);
  if (accessCode.length > FieldLimits.reviewAccessCode) {
    return json({ error: "accessCode is too large" }, 400);
  }
  if (input.label && input.label.length > FieldLimits.apiKeyLabel) {
    return json({ error: "label is too large" }, 400);
  }
  if (input.deviceId && input.deviceId.length > FieldLimits.deviceId) {
    return json({ error: "deviceId is too large" }, 400);
  }

  let auth;
  try {
    auth = await authenticateReviewAccessCode(req, env, accessCode);
  } catch (error) {
    if (error instanceof AuthRateLimitError) {
      return json({ error: "too many attempts" }, 429, { "retry-after": "60" });
    }
    if (error instanceof AuthError) return json({ error: "invalid review access code" }, 401);
    throw error;
  }

  const created = await issueAppCredentialBundle(env, {
    tenantId: auth.tenantId,
    ownerEmail: auth.ownerEmail!,
    label: input.label?.trim() || "iOS review app",
    deviceId: input.deviceId?.trim() || undefined,
    issuePublisherCredential: input.issuePublisherCredential,
  });
  return json(created, 201);
}
