import type { AuthContext } from "./auth";
import { json } from "./http";
import { listTenantRateLimitBuckets, tenantKey } from "./rateLimit";
import { isSharingEnabled } from "./shares";
import { mcpConfigured } from "./mcpOAuth";
import * as storage from "./storage";
import {
  isSubscriptionRequired,
  isSubscriptionsEnabled,
  readSubscriptionState,
} from "./subscription";
import { listActiveActivitySessions } from "./liveActivities";
import {
  WIDGET_PUSH_BURST,
  WIDGET_PUSH_MIN_SPACING_SECONDS,
  WIDGET_PUSH_REFILL_SECONDS,
  widgetPushWaitForTokens,
  widgetPushApnsDiagnosticsEnabled,
} from "./widgetPush";
import type { Env } from "./types";

// The ActivityAttributes type the iOS app registers a push-to-start token
// under. Duplicated rather than imported to avoid a cycle with liveActivities.
const DEFAULT_ATTRIBUTES_TYPE = "ZeroZeroWidgetActivityAttributes";

/// GET /v1/status — everything a producer needs to know about where its
/// publishes are going, before it wonders why nothing appeared.
///
/// Nothing here is new information; all of it was already in D1 or in `env`,
/// and none of it was reachable. A producer holding a valid token could not
/// find out which scopes it had (it discovered them by getting a 403), whether
/// any device would receive what it published, how much of the hour's budget it
/// had left, or whether the deployment enforced subscriptions. Several sections
/// of the integration guide exist only to say in prose what one call can
/// answer for the deployment actually in front of you.
///
/// Deliberately open to any credential that can read, and never gated on a
/// subscription: an account that has lapsed is exactly the one that needs to
/// find out why its writes are failing.
export async function getStatus(
  _req: Request,
  env: Env,
  auth: AuthContext,
): Promise<Response> {
  const diagnosticsEnabled = widgetPushApnsDiagnosticsEnabled(env);
  const [cards, activities, devices, widgetTokens, startTokens, buckets, widgetDeliveries] = await Promise.all([
    storage.listCards(env, auth.tenantId),
    listActiveActivitySessions(env, auth.tenantId),
    storage.listTenantDevices(env, auth.tenantId),
    storage.listWidgetTokens(env, auth.tenantId),
    storage.listStartTokens(env, auth.tenantId, DEFAULT_ATTRIBUTES_TYPE),
    listTenantRateLimitBuckets(env, auth.tenantId),
    diagnosticsEnabled
      ? storage.listWidgetPushDeliveryDiagnostics(env, auth.tenantId)
      : Promise.resolve([]),
  ]);

  // Reuses the token list already fetched above; asking by tenant would list
  // them a second time for the same answer.
  const secondsUntilReload = await widgetPushWaitForTokens(env, widgetTokens);

  const subscription = isSubscriptionsEnabled(env)
    ? {
      enabled: true,
      required: isSubscriptionRequired(env),
      state: await readSubscriptionState(env, auth.tenantId),
    }
    : { enabled: false, required: false };

  return json({
    account: {
      tenantId: auth.tenantId,
      // The same id that arrives as `accountId` on a webhook delivery, so the
      // two can be reconciled without guessing.
      credentialKind: auth.credentialKind,
      scopes: auth.scopes,
      // Sliding: every authenticated call pushes it out again, so a live
      // integration never reaches it.
      credentialExpiresAt: auth.expiresAt,
    },
    delivery: {
      devices: devices.length,
      widgetPushTokens: widgetTokens.length,
      liveActivityStartTokens: startTokens.length,
      // The two questions a producer actually has. `false` for either means
      // what you publish is stored correctly and seen by nobody — the operator
      // has not installed the app, or has not allowed notifications.
      canPushWidgets: widgetTokens.length > 0,
      canStartLiveActivities: startTokens.length > 0,
      // The shortest gap between two reload pushes to the same widget, and how
      // many a widget gets per rolling day. Publishes in between are stored
      // immediately and coalesced into the next reload, so a card is never out
      // of date on the device — it is just not redrawn yet.
      widgetReloadMinSpacingSeconds: WIDGET_PUSH_MIN_SPACING_SECONDS,
      // A bucket, not a quota: `burst` reloads may go out close together, and
      // one more becomes available every `refill` seconds thereafter. So a
      // widget can respond quickly to a change and still never run dry.
      widgetReloadBurst: WIDGET_PUSH_BURST,
      widgetReloadRefillSeconds: WIDGET_PUSH_REFILL_SECONDS,
      secondsUntilNextWidgetReload: secondsUntilReload,
      widgetPushApnsDiagnosticsEnabled: diagnosticsEnabled,
      // Latest final APNs result per currently registered token. This is
      // present only while diagnostics are enabled, avoiding even a read when
      // the opt-in flag is off.
      ...(diagnosticsEnabled ? { widgetPushLastDeliveries: widgetDeliveries } : {}),
    },
    published: {
      cards: cards.length,
      liveActivities: activities.length,
    },
    // What this deployment has turned on, which a producer cannot otherwise
    // tell apart from a feature it is calling wrong.
    features: {
      sharing: isSharingEnabled(env),
      mcp: mcpConfigured(env),
    },
    subscription,
    // Only the windows this tenant has actually touched appear; an untouched
    // limit has its full allowance and no row to report.
    rateLimits: buckets
      .filter((bucket) => bucket.bucketKey.includes(tenantKey(auth.tenantId)))
      .map((bucket) => ({
        label: bucket.label,
        limit: bucket.limit,
        remaining: bucket.remaining,
        resetAt: new Date(bucket.resetAt * 1000).toISOString(),
      })),
  });
}
