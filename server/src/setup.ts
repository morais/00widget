import { z } from "zod";
import { isReviewTenant } from "./reviewAuth";
import { partitionStartTokens } from "./startTokenFreshness";
import * as storage from "./storage";
import { isSubscriptionRequired, readSubscriptionState } from "./subscription";
import type { Env } from "./types";

export const APP_STORE_URL = "https://apps.apple.com/app/id6764778433";
const ATTRIBUTES_TYPE = "ZeroZeroWidgetActivityAttributes";

// Kept separate from MCP descriptors: their published, open schemas already
// permit additive fields. This schema validates the advisory in our tests only.
export const SetupSchema = z.strictObject({
  status: z.enum(["ready", "finish_setup", "unknown"]),
  optional: z.literal(true),
  appStoreUrl: z.url().optional(),
  question: z.string().optional(),
  instructions: z.array(z.string()).optional(),
});
export type Setup = z.infer<typeof SetupSchema>;

export async function recordNativeSignIn(env: Env, tenantId: string): Promise<void> {
  await env.ZW_DB.prepare(
    `UPDATE tenants SET first_native_sign_in_at = ?
     WHERE id = ? AND first_native_sign_in_at IS NULL`,
  ).bind(new Date().toISOString(), tenantId).run();
}

interface SetupEvidence {
  widgetTokens: string[];
  startTokens: storage.StartTokenRow[];
  subscriptionActive: boolean;
}

/// Account-scoped iPhone delivery readiness, never an authorization gate.
/// A widget and a Live Activity are alternatives; do not demand both. The
/// server cannot observe widget placement or the on-device permission UI.
export async function readSetup(
  env: Env,
  tenantId: string,
  evidence?: SetupEvidence,
): Promise<Setup> {
  let status: Setup["status"] = "unknown";
  try {
    status = await resolveSetupStatus(env, tenantId, evidence);
  } catch {
    // An advisory lookup must not make an otherwise valid data read fail.
    // Log no identity, token, or database error text from this extra lookup.
    console.warn("setup evidence unavailable");
  }
  if (status === "ready") return { status, optional: true };
  return {
    status,
    optional: true,
    appStoreUrl: APP_STORE_URL,
    ...(status === "unknown" ? {
      question: "Have you already configured the 00Widget app? Native setup could not be confirmed; do not assume it is missing.",
    } : {}),
    instructions: [
      "Offer this setup help if wanted; the connection and existing reads remain available.",
      `Open 00Widget, or install it from ${APP_STORE_URL}.`,
      "Sign in with the same Apple account used to connect 00Widget in chat.",
      "Complete setup in the app. Allow notifications and Live Activities to receive live updates, or add a Home Screen widget for card updates.",
      ...(isSubscriptionRequired(env) ? ["If the app requests a subscription, activate or restore it there."] : []),
      "Return to this chat. Keep the plugin or connector connected; do not disconnect or reinstall it.",
      "Recheck by calling this same tool again with the same arguments; for HTTP, repeat this same read request.",
    ],
  };
}

async function resolveSetupStatus(
  env: Env,
  tenantId: string,
  evidence?: SetupEvidence,
): Promise<Setup["status"]> {
  // Explicitly provisioned review fixtures must remain usable without a
  // reviewer's own Apple account, device or purchase. Never expose the allowlist.
  if (isReviewTenant(env, tenantId)) return "ready";
  const account = await env.ZW_DB.prepare(
    `SELECT first_native_sign_in_at FROM tenants WHERE id = ?`,
  ).bind(tenantId).first<{ first_native_sign_in_at: string | null }>();
  const signedIn = Boolean(account?.first_native_sign_in_at);
  const required = isSubscriptionRequired(env);
  const delivery = evidence ?? (signedIn ? await loadEvidence(env, tenantId, required) : null);
  const canDeliver = delivery !== null && (
    delivery.widgetTokens.length > 0 || partitionStartTokens(delivery.startTokens).live.length > 0
  );
  if (signedIn && canDeliver && (!required || delivery?.subscriptionActive)) {
    return "ready";
  }
  return signedIn ? "finish_setup" : "unknown";
}

async function loadEvidence(env: Env, tenantId: string, required: boolean): Promise<SetupEvidence> {
  const [widgetTokens, startTokens, subscriptionActive] = await Promise.all([
    storage.listWidgetTokens(env, tenantId),
    storage.listStartTokens(env, tenantId, ATTRIBUTES_TYPE),
    required ? readSubscriptionState(env, tenantId).then((state) => state.active) : Promise.resolve(true),
  ]);
  return { widgetTokens, startTokens, subscriptionActive };
}
