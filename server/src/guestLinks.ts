import type { Env, GuestResourceKind } from "./types";
import {
  CreateGuestLinkSchema,
  GuestLinkTtl,
  RegisterGuestActivitySchema,
  RequestBodyLimits,
} from "./types";
import { json, badRequest, notFound } from "./http";
import type { AuthContext } from "./auth";
import {
  ApiScopePresets,
  countLiveGuestApiKeys,
  createApiKey,
  getGuestApiKey,
  listLiveGuestApiKeys,
  pruneExpiredGuestApiKeys,
  revokeApiKey,
} from "./auth";
import { parseJson } from "./cards";
import { enforceRateLimits, enforceTenantRateLimits, guestCredentialKey, tenantKey } from "./rateLimit";
import * as storage from "./storage";

// Guest links let someone who has no 00Widget account watch exactly one card or
// one Live Activity. The credential is an api_keys row of kind "guest" bound to
// a single resource id — see migrations/0020_guest_links.sql for why it lives
// there rather than in a table of its own.
//
// The token travels in the URL *fragment*, never the path:
//
//     https://api.example.com/app/g#<token>
//
// Fragments are not sent to servers, so the bearer token stays out of request
// logs at Cloudflare and anywhere else in front of this Worker. The fallback
// page reads it client-side. Anything that builds a guest URL must keep the
// "#" — moving the token into the path would quietly start logging it.
export const GUEST_LINK_PATH = "/app/g";

/// Ceiling on live links per tenant. Each one is a bearer credential someone
/// may still be holding, so the standing total matters more than the rate.
export const MAX_LIVE_GUEST_LINKS = 200;

export function guestLinkUrl(origin: string, token: string): string {
  return `${origin}${GUEST_LINK_PATH}#${token}`;
}

function ttlLimitsFor(kind: GuestResourceKind): { def: number; max: number } {
  return kind === "activity"
    ? { def: GuestLinkTtl.activityDefaultSeconds, max: GuestLinkTtl.activityMaxSeconds }
    : { def: GuestLinkTtl.cardDefaultSeconds, max: GuestLinkTtl.cardMaxSeconds };
}

/// POST /v1/shares/guest — mint a link for one resource the caller owns.
export async function createGuestLink(
  req: Request,
  env: Env,
  auth: AuthContext,
): Promise<Response> {
  const body = await parseJson(req, RequestBodyLimits.guestLink);
  const parsed = CreateGuestLinkSchema.safeParse(body);
  if (!parsed.success) return badRequest(`validation failed: ${parsed.error.message}`);
  // Minting is a share mutation, not a registration. Spending the registration
  // budget here would let someone who hands out links lose the ability to
  // register their own devices and Live Activities.
  const limited = await enforceTenantRateLimits(env, auth, [
    { policy: "shareTenantDay", key: tenantKey(auth.tenantId) },
  ]);
  if (limited) return limited;

  const { resourceKind, resourceId, ttlSeconds, label } = parsed.data;

  // Cheap and infrequent enough to piggyback on: guest rows are the only ones
  // that expire freely and in volume, and nothing else would ever remove them.
  await pruneExpiredGuestApiKeys(env);

  // A daily rate limit caps how fast links appear, not how many exist at once.
  // Every live link is a bearer credential in the world, so the standing total
  // needs its own ceiling.
  if (await countLiveGuestApiKeys(env, auth.tenantId) >= MAX_LIVE_GUEST_LINKS) {
    return json({
      error: `too many active guest links (limit ${MAX_LIVE_GUEST_LINKS}); revoke some first`,
    }, 429, { "retry-after": "3600" });
  }

  // Mint only for something the caller actually owns, and only for something
  // that exists: a link to a missing resource is a token in the world that can
  // never show anything.
  if (resourceKind === "card") {
    const card = await storage.getCard(env, auth.tenantId, resourceId);
    if (!card) return notFound();
  } else {
    const instance = await storage.getActivityInstanceForTarget(env, resourceId, auth.tenantId);
    if (!instance) return notFound();
  }

  const limits = ttlLimitsFor(resourceKind);
  const ttl = Math.min(ttlSeconds ?? limits.def, limits.max);
  const expiresAt = new Date(Date.now() + ttl * 1000).toISOString();

  const created = await createApiKey(env, {
    tenantId: auth.tenantId,
    kind: "guest",
    // Inherit the minting session so signing out revokes this link along with
    // everything else that session issued.
    sessionId: auth.sessionId,
    label: label ?? `guest ${resourceKind}`,
    scopes: ApiScopePresets.guest,
    resourceKind,
    resourceId,
    expiresAt,
  });

  return json({
    id: created.apiKey.id,
    token: created.token,
    url: guestLinkUrl(new URL(req.url).origin, created.token),
    resourceKind,
    resourceId,
    expiresAt,
  }, 201);
}

/// GET /v1/shares/guest — the caller's live guest links. Never returns tokens:
/// they exist only in the response that minted them and on whatever QR code the
/// app rendered from it.
export async function listGuestLinks(
  _req: Request,
  env: Env,
  auth: AuthContext,
): Promise<Response> {
  const links = (await listLiveGuestApiKeys(env, auth.tenantId))
    .map((key) => ({
      id: key.id,
      label: key.label,
      resourceKind: key.resourceKind,
      resourceId: key.resourceId,
      createdAt: key.createdAt,
      expiresAt: key.expiresAt,
      lastUsedAt: key.lastUsedAt,
    }));
  return json({ links });
}

/// DELETE /v1/shares/guest/:id
export async function revokeGuestLink(
  _req: Request,
  env: Env,
  auth: AuthContext,
  id: string,
): Promise<Response> {
  // Scoped to the caller's tenant, so an id from another tenant is
  // indistinguishable from one that never existed.
  const target = await getGuestApiKey(env, auth.tenantId, id);
  if (!target) return notFound();
  const revoked = await revokeApiKey(env, id);
  return json({ ok: true, revoked });
}

/// GET /v1/guest/resource — the one card or activity this credential unlocks.
export async function getGuestResource(
  _req: Request,
  env: Env,
  auth: AuthContext,
): Promise<Response> {
  const binding = guestBinding(auth);
  if (!binding) return badRequest("credential is not bound to a resource");

  if (binding.resourceKind === "card") {
    const card = await storage.getCard(env, auth.tenantId, binding.resourceId);
    if (!card) return notFound();
    // Actions are stripped: a guest holds a view-only credential, and leaving
    // buttons on a shared card would advertise affordances that correctly 403.
    const { actions: _actions, ...viewOnly } = card;
    return json({ resourceKind: "card", card: viewOnly, expiresAt: auth.expiresAt });
  }

  const instance = await storage.getActivityInstanceForTarget(
    env,
    binding.resourceId,
    auth.tenantId,
  );
  if (!instance) return notFound();
  return json({ resourceKind: "activity", activity: instance, expiresAt: auth.expiresAt });
}

/// POST /v1/guest/live-activities/register — the guest's device asks to receive
/// this activity's updates, so the link keeps working after the app is closed.
export async function registerGuestActivity(
  req: Request,
  env: Env,
  auth: AuthContext,
): Promise<Response> {
  const binding = guestBinding(auth);
  if (!binding) return badRequest("credential is not bound to a resource");
  if (binding.resourceKind !== "activity") {
    return badRequest("credential is not bound to a Live Activity");
  }
  const body = await parseJson(req, RequestBodyLimits.registration);
  const parsed = RegisterGuestActivitySchema.safeParse(body);
  if (!parsed.success) return badRequest(`validation failed: ${parsed.error.message}`);
  // Deliberately not enforceTenantRateLimits: that also charges the owner's
  // hourly write budget. A guest must not be able to spend the owner's
  // allowance at all, so this is keyed on the guest credential alone.
  const limited = await enforceRateLimits(env, [
    { policy: "guestRegistrationDay", key: guestCredentialKey(auth.apiKeyId) },
  ]);
  if (limited) return limited;

  const instance = await storage.getActivityInstanceForTarget(
    env,
    binding.resourceId,
    auth.tenantId,
  );
  if (!instance) return notFound();

  const now = new Date().toISOString();
  // Recorded under the guest credential's own hash, which is what makes the
  // registration disappear with the link: sign-out cleans up deliveries by the
  // hashes belonging to the session, and revocation strands nothing behind.
  await storage.putActivityDelivery(env, {
    activityInstanceId: instance.activityInstanceId,
    ownerTenantId: auth.tenantId,
    targetTenantId: auth.tenantId,
    apiKeyHash: auth.apiKeyHash,
    record: {
      deviceId: parsed.data.deviceId,
      localActivityId: parsed.data.localActivityId,
      kind: instance.kind,
      title: instance.title,
      pushToken: parsed.data.pushToken,
      updatedAt: now,
    },
  });

  return json({ ok: true, activityInstanceId: instance.activityInstanceId });
}

function guestBinding(
  auth: AuthContext,
): { resourceKind: GuestResourceKind; resourceId: string } | null {
  if (auth.resourceKind !== "card" && auth.resourceKind !== "activity") return null;
  if (!auth.resourceId) return null;
  return { resourceKind: auth.resourceKind, resourceId: auth.resourceId };
}
