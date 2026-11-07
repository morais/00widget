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
  await nativeSignInStatement(env, tenantId).run();
}

export function nativeSignInStatement(env: Env, tenantId: string): D1PreparedStatement {
  return env.ZW_DB.prepare(
    `UPDATE tenants SET first_native_sign_in_at = ?
     WHERE id = ? AND first_native_sign_in_at IS NULL`,
  ).bind(new Date().toISOString(), tenantId);
}

interface SetupEvidence {
  widgetTokens: string[];
  startTokens: storage.StartTokenRow[];
  subscriptionActive: boolean;
}

/// Native app readiness, never an authorization gate. A headset polls with
/// its own credential; iPhone widget/Live Activity push is an alternative.
export async function readSetup(
  env: Env,
  tenantId: string,
  evidence?: SetupEvidence,
): Promise<Setup> {
  let status: Setup["status"] = "unknown";
  let horizon = false;
  try {
    ({ status, horizon } = await resolveSetupStatus(env, tenantId, evidence));
  } catch {
    // An advisory lookup must not make an otherwise valid data read fail.
    // Log no identity, token, or database error text from this extra lookup.
    console.warn("setup evidence unavailable");
  }
  if (status === "ready") return { status, optional: true };
  return {
    status,
    optional: true,
    ...(!horizon ? { appStoreUrl: APP_STORE_URL } : {}),
    ...(status === "unknown" ? {
      question: "Have you already configured the 00Widget app? Native setup could not be confirmed; do not assume it is missing.",
    } : {}),
    instructions: [
      "Offer this setup help if wanted; the connection and existing reads remain available.",
      ...(horizon ? [
        "Open 00Widget on your Meta Quest and sign in with the same Meta account used for this chat connection. If you linked an Apple account, reconnect to that same account from the headset.",
        "Complete setup in the headset app and open its dashboard. Horizon reads updates directly; iPhone setup and push permissions are optional.",
      ] : [
        `Open 00Widget, or install it from ${APP_STORE_URL}.`,
        "Sign in with the same Apple account used to connect 00Widget in chat.",
        "Complete setup in the app. Allow notifications and Live Activities to receive live updates, or add a Home Screen widget for card updates.",
      ]),
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
): Promise<{ status: Setup["status"]; horizon: boolean }> {
  // Explicitly provisioned review fixtures must remain usable without a
  // reviewer's own Apple account, device or purchase. Never expose the allowlist.
  if (isReviewTenant(env, tenantId)) return { status: "ready", horizon: false };
  const [account, nativeHorizon] = await Promise.all([
    env.ZW_DB.prepare(
      `SELECT first_native_sign_in_at FROM tenants WHERE id = ?`,
    ).bind(tenantId).first<{ first_native_sign_in_at: string | null }>(),
    readHorizonEvidence(env, tenantId),
  ]);
  const horizon = Boolean(nativeHorizon?.horizon);
  const signedIn = Boolean(account?.first_native_sign_in_at);
  const required = isSubscriptionRequired(env);
  const delivery = evidence ?? (signedIn ? await loadEvidence(env, tenantId, required) : null);
  const canDeliver = Boolean(nativeHorizon?.configured) || (delivery !== null && (
    delivery.widgetTokens.length > 0 || partitionStartTokens(delivery.startTokens).live.length > 0
  ));
  if (signedIn && canDeliver && (!required || delivery?.subscriptionActive)) {
    return { status: "ready", horizon };
  }
  return { status: signedIn ? "finish_setup" : "unknown", horizon };
}

function readHorizonEvidence(env: Env, tenantId: string) {
  // Only native Horizon sign-in/device exchange issues kind=app/purpose=device.
  // Publisher labels, browser sessions and connector credentials cannot qualify.
  return env.ZW_DB.prepare(
    `SELECT EXISTS (
       SELECT 1 FROM api_keys WHERE tenant_id = ? AND kind = 'app' AND purpose = 'device'
         AND revoked_at IS NULL AND expires_at > ?
     ) AS configured,
     (EXISTS (SELECT 1 FROM horizon_accounts WHERE tenant_id = ?)
      OR EXISTS (SELECT 1 FROM api_keys WHERE tenant_id = ? AND kind = 'app' AND purpose = 'device')) AS horizon`,
  ).bind(tenantId, new Date().toISOString(), tenantId, tenantId)
    .first<{ configured: number; horizon: number }>();
}

async function loadEvidence(env: Env, tenantId: string, required: boolean): Promise<SetupEvidence> {
  const [widgetTokens, startTokens, subscriptionActive] = await Promise.all([
    storage.listWidgetTokens(env, tenantId),
    storage.listStartTokens(env, tenantId, ATTRIBUTES_TYPE),
    required ? readSubscriptionState(env, tenantId).then((state) => state.active) : Promise.resolve(true),
  ]);
  return { widgetTokens, startTokens, subscriptionActive };
}
