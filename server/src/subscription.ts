import { verifyAppleJws, AppleJwsError, decodeAppleJwsPayloadUnverified } from "./appleJws";
import { APPLE_ROOT_CA_G3_DER } from "./appleRootCA";
import type { AuthContext } from "./auth";
import { parseJson } from "./cards";
import { badRequest, json, notFound } from "./http";
import { enforceRateLimits } from "./rateLimit";
import { RequestBodyLimits, type Env } from "./types";

// App Store subscription entitlements.
//
// Two flags, deliberately separate:
//
//   SUBSCRIPTIONS_ENABLED  — verify and record what Apple signs.
//   SUBSCRIPTION_REQUIRED  — refuse writes from tenants without an entitlement.
//
// The middle state is the useful one: selling subscriptions while grandfathering
// existing tenants, or watching the verification pipeline produce correct data
// for a week before letting it reject anything.
//
// Requiring without enabling fails *open*. A misconfigured kill switch that
// locks out every paying customer is a worse outcome than one that bills nobody,
// and unlike the security flags in this codebase there is nothing to leak.

export function isSubscriptionsEnabled(env: Env): boolean {
  return (env.SUBSCRIPTIONS_ENABLED ?? "").trim().toLowerCase() === "true";
}

export function isSubscriptionRequired(env: Env): boolean {
  if (!isSubscriptionsEnabled(env)) return false;
  return (env.SUBSCRIPTION_REQUIRED ?? "").trim().toLowerCase() === "true";
}

export function subscriptionsDisabledResponse(): Response {
  return notFound();
}

/// Days past `expires_at` that a lapsed entitlement still counts as active.
///
/// Distinct from Apple's own billing grace period, which arrives in the payload
/// and is stored. This one covers the gap the server can see and Apple cannot:
/// a notification that arrives late, or a renewal that has happened but whose
/// payload has not reached us. Blanking a paying customer's dashboard because a
/// webhook was slow is the failure worth spending a few days of slack on.
const DEFAULT_GRACE_DAYS = 3;

function graceMs(env: Env): number {
  const raw = Number((env.SUBSCRIPTION_GRACE_DAYS ?? "").trim());
  const days = Number.isFinite(raw) && raw >= 0 ? raw : DEFAULT_GRACE_DAYS;
  return days * 24 * 60 * 60 * 1000;
}

function configuredProductIds(env: Env): string[] {
  return (env.SUBSCRIPTION_PRODUCT_IDS ?? "")
    .split(",")
    .map((id) => id.trim())
    .filter(Boolean);
}

export type SubscriptionStatus = "active" | "trial" | "grace" | "expired" | "revoked" | "none";

export interface SubscriptionState {
  status: SubscriptionStatus;
  active: boolean;
  productId?: string;
  expiresAt?: string;
  autoRenew?: boolean;
  environment?: string;
}

export const NO_SUBSCRIPTION: SubscriptionState = { status: "none", active: false };

export interface SubscriptionRow {
  original_transaction_id: string;
  tenant_id: string | null;
  product_id: string;
  status: string;
  expires_at_ms: number | null;
  grace_expires_at_ms: number | null;
  is_trial: number;
  auto_renew: number;
  environment: string;
  revoked_at_ms: number | null;
  signed_date_ms: number;
}

/// Turns a stored row into the entitlement decision. All the policy lives here
/// so the route layer, the app, and the tests cannot disagree about what
/// "active" means.
export function evaluateSubscription(
  row: SubscriptionRow | null,
  env: Env,
  now = Date.now(),
): SubscriptionState {
  if (!row) return NO_SUBSCRIPTION;

  const base: SubscriptionState = {
    status: "expired",
    active: false,
    productId: row.product_id,
    expiresAt: row.expires_at_ms ? new Date(row.expires_at_ms).toISOString() : undefined,
    autoRenew: row.auto_renew === 1,
    environment: row.environment,
  };

  // A refund outranks any expiry date still sitting in the row.
  if (row.revoked_at_ms !== null && row.revoked_at_ms <= now) {
    return { ...base, status: "revoked" };
  }

  const expiresAt = row.expires_at_ms;
  if (expiresAt === null) return { ...base, status: "expired" };

  if (now <= expiresAt) {
    return { ...base, status: row.is_trial === 1 ? "trial" : "active", active: true };
  }

  // Apple's billing grace period, then ours. Whichever reaches further wins;
  // they cover different failures and there is no reason to take the shorter.
  const graceUntil = Math.max(row.grace_expires_at_ms ?? 0, expiresAt + graceMs(env));
  if (now <= graceUntil) return { ...base, status: "grace", active: true };

  return base;
}

export async function readSubscriptionRow(
  env: Env,
  tenantId: string,
): Promise<SubscriptionRow | null> {
  // A tenant can hold more than one row: resubscribing after a lapse mints a
  // new originalTransactionId. The one that reaches furthest into the future
  // is the one that decides, so ordering beats picking the newest by date.
  return env.ZW_DB.prepare(
    `SELECT original_transaction_id, tenant_id, product_id, status, expires_at_ms,
            grace_expires_at_ms, is_trial, auto_renew, environment, revoked_at_ms,
            signed_date_ms
     FROM subscriptions
     WHERE tenant_id = ?
     ORDER BY COALESCE(expires_at_ms, 0) DESC
     LIMIT 1`,
  )
    .bind(tenantId)
    .first<SubscriptionRow>();
}

export async function readSubscriptionState(
  env: Env,
  tenantId: string,
): Promise<SubscriptionState> {
  if (!isSubscriptionsEnabled(env)) return NO_SUBSCRIPTION;
  return evaluateSubscription(await readSubscriptionRow(env, tenantId), env);
}

// ---------------------------------------------------------------------------
// Recording what Apple signs
// ---------------------------------------------------------------------------

/// The fields this server reads out of a decoded transaction. Apple sends many
/// more; anything not listed is deliberately ignored rather than stored.
///
/// Verified 2026-08-19 against
/// https://developer.apple.com/documentation/appstoreserverapi/jwstransactiondecodedpayload
interface DecodedTransaction {
  originalTransactionId: string;
  productId: string;
  bundleId: string;
  environment: string;
  expiresDate?: number;
  revocationDate?: number;
  signedDate?: number;
  offerType?: number;
  offerDiscountType?: string;
  type?: string;
}

export class SubscriptionRejected extends Error {
  constructor(message: string) {
    super(message);
    this.name = "SubscriptionRejected";
  }
}

function requireString(payload: Record<string, unknown>, key: string): string {
  const value = payload[key];
  if (typeof value !== "string" || !value.trim()) {
    throw new SubscriptionRejected(`transaction is missing ${key}`);
  }
  return value.trim();
}

function optionalNumber(payload: Record<string, unknown>, key: string): number | undefined {
  const value = payload[key];
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

/// Verifies a signed transaction and checks it belongs to this deployment.
export async function verifyTransaction(
  env: Env,
  signedTransaction: string,
): Promise<DecodedTransaction> {
  let payload: Record<string, unknown>;
  try {
    payload = await verifyAppleJws(signedTransaction, {
      trustedRootDer: APPLE_ROOT_CA_G3_DER,
    });
  } catch (err) {
    if (err instanceof AppleJwsError) throw new SubscriptionRejected(err.message);
    throw err;
  }

  const bundleId = requireString(payload, "bundleId");
  const expectedBundleId = (env.APNS_BUNDLE_ID ?? "").trim();
  // A signature only proves Apple signed it — not that it was signed for us.
  // Without this check, any Apple-signed transaction from any app on the store
  // would entitle a tenant here.
  if (expectedBundleId && bundleId !== expectedBundleId) {
    throw new SubscriptionRejected("transaction is for a different app");
  }

  const productId = requireString(payload, "productId");
  const allowed = configuredProductIds(env);
  if (allowed.length > 0 && !allowed.includes(productId)) {
    throw new SubscriptionRejected("transaction is for an unrecognised product");
  }

  const environment = requireString(payload, "environment");
  // Sandbox purchases are free and unlimited. Letting one entitle a production
  // tenant would make the paywall decorative.
  const expectedEnvironment = (env.SUBSCRIPTION_ENVIRONMENT ?? "Production").trim();
  if (environment.toLowerCase() !== expectedEnvironment.toLowerCase()) {
    throw new SubscriptionRejected(`transaction is from the ${environment} environment`);
  }

  return {
    originalTransactionId: requireString(payload, "originalTransactionId"),
    productId,
    bundleId,
    environment,
    expiresDate: optionalNumber(payload, "expiresDate"),
    revocationDate: optionalNumber(payload, "revocationDate"),
    signedDate: optionalNumber(payload, "signedDate"),
    offerType: optionalNumber(payload, "offerType"),
    offerDiscountType:
      typeof payload.offerDiscountType === "string" ? payload.offerDiscountType : undefined,
    type: typeof payload.type === "string" ? payload.type : undefined,
  };
}

/// Writes a verified transaction to `subscriptions`.
///
/// `tenantId` is undefined for a notification, which carries no identity —
/// those rows stay unclaimed until the app next verifies. It is never taken
/// from a request body: which tenant a purchase belongs to is decided by the
/// authenticated caller, in keeping with a handler re-resolving what an
/// identity may touch.
export async function recordTransaction(
  env: Env,
  transaction: DecodedTransaction,
  tenantId?: string,
): Promise<void> {
  const now = new Date().toISOString();
  const signedDate = transaction.signedDate ?? 0;
  // A free trial is an introductory offer, which Apple flags as offerType 1.
  const isTrial = transaction.offerType === 1 ? 1 : 0;

  // ON CONFLICT rather than INSERT OR REPLACE, for two reasons. An existing
  // tenant_id is never overwritten with NULL — a notification arriving after
  // the app has claimed the row must not orphan it again. And an older payload
  // never overwrites a newer one: Apple does not guarantee notification
  // ordering, so a delayed EXPIRED can arrive after the DID_RENEW that
  // superseded it.
  await env.ZW_DB.prepare(
    `INSERT INTO subscriptions
       (original_transaction_id, tenant_id, product_id, status, expires_at_ms,
        grace_expires_at_ms, is_trial, auto_renew, environment, revoked_at_ms,
        signed_date_ms, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT (original_transaction_id) DO UPDATE SET
       tenant_id = COALESCE(excluded.tenant_id, subscriptions.tenant_id),
       product_id = excluded.product_id,
       status = excluded.status,
       expires_at_ms = excluded.expires_at_ms,
       grace_expires_at_ms = excluded.grace_expires_at_ms,
       is_trial = excluded.is_trial,
       auto_renew = excluded.auto_renew,
       environment = excluded.environment,
       revoked_at_ms = excluded.revoked_at_ms,
       signed_date_ms = excluded.signed_date_ms,
       updated_at = excluded.updated_at
     WHERE excluded.signed_date_ms >= subscriptions.signed_date_ms`,
  )
    .bind(
      transaction.originalTransactionId,
      tenantId ?? null,
      transaction.productId,
      transaction.revocationDate ? "revoked" : "active",
      transaction.expiresDate ?? null,
      null,
      isTrial,
      1,
      transaction.environment,
      transaction.revocationDate ?? null,
      signedDate,
      now,
      now,
    )
    .run();
}

/// Claims an unowned row, or confirms the caller already owns it.
///
/// Refuses to move a row between tenants. One App Store purchase entitles one
/// account: without this, signing in as a second identity and replaying the
/// same receipt would entitle both.
export async function claimTransactionForTenant(
  env: Env,
  originalTransactionId: string,
  tenantId: string,
): Promise<void> {
  const existing = await env.ZW_DB.prepare(
    `SELECT tenant_id FROM subscriptions WHERE original_transaction_id = ?`,
  )
    .bind(originalTransactionId)
    .first<{ tenant_id: string | null }>();
  if (existing?.tenant_id && existing.tenant_id !== tenantId) {
    throw new SubscriptionRejected("this purchase is already linked to another account");
  }
  if (existing?.tenant_id === tenantId) return;
  await env.ZW_DB.prepare(
    `UPDATE subscriptions
     SET tenant_id = ?, updated_at = ?
     WHERE original_transaction_id = ? AND tenant_id IS NULL`,
  )
    .bind(tenantId, new Date().toISOString(), originalTransactionId)
    .run();
}

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------

interface VerifyRequest {
  signedTransactions?: unknown;
}

/// POST /v1/subscription/verify — the app forwards what StoreKit gave it.
///
/// The fast path. A purchase is live here within a second, rather than whenever
/// Apple's next notification happens to arrive.
export async function verifySubscription(
  req: Request,
  env: Env,
  auth: AuthContext,
): Promise<Response> {
  if (!isSubscriptionsEnabled(env)) return subscriptionsDisabledResponse();

  let body: VerifyRequest;
  try {
    body = (await parseJson(req, RequestBodyLimits.subscriptionVerify)) as VerifyRequest;
  } catch {
    return badRequest("missing JSON body");
  }
  const signed = body?.signedTransactions;
  if (!Array.isArray(signed) || signed.length === 0) {
    return badRequest("signedTransactions must be a non-empty array");
  }
  if (signed.length > MAX_TRANSACTIONS_PER_VERIFY) {
    return badRequest("too many transactions");
  }
  if (signed.some((entry) => typeof entry !== "string")) {
    return badRequest("signedTransactions must contain JWS strings");
  }

  const limited = await enforceRateLimits(env, [
    { policy: "subscriptionVerifyTenantHour", key: `tenant:${auth.tenantId}` },
  ]);
  if (limited) return limited;

  const rejections: string[] = [];
  let accepted = 0;
  for (const signedTransaction of signed as string[]) {
    try {
      const transaction = await verifyTransaction(env, signedTransaction);
      await claimTransactionForTenant(env, transaction.originalTransactionId, auth.tenantId);
      await recordTransaction(env, transaction, auth.tenantId);
      accepted++;
    } catch (err) {
      if (err instanceof SubscriptionRejected) {
        rejections.push(err.message);
        continue;
      }
      throw err;
    }
  }

  // StoreKit hands over every entitlement it holds, which legitimately includes
  // products from a group this deployment does not sell. Rejecting all of them
  // is an error; rejecting some is routine, so the rejections are reported
  // alongside a successful result rather than instead of one.
  if (accepted === 0) {
    return json({ error: rejections[0] ?? "no usable transactions", rejected: rejections }, 400);
  }

  const state = await readSubscriptionState(env, auth.tenantId);
  return json({ subscription: state, accepted, rejected: rejections });
}

const MAX_TRANSACTIONS_PER_VERIFY = 20;

/// GET /v1/subscription — what the app shows in its settings.
export async function getSubscription(
  _req: Request,
  env: Env,
  auth: AuthContext,
): Promise<Response> {
  if (!isSubscriptionsEnabled(env)) return subscriptionsDisabledResponse();
  const state = await readSubscriptionState(env, auth.tenantId);
  return json({
    subscription: state,
    // The app cannot infer this: an entitlement being absent means something
    // different where writes are gated than where they are not.
    required: isSubscriptionRequired(env),
    productIds: configuredProductIds(env),
  });
}

/// POST /v1/apple/subscription-notifications — App Store Server Notifications V2.
///
/// Unauthenticated by necessity: Apple presents no credential, and the JWS
/// signature is the authentication. Without this endpoint the stored state is
/// simply wrong — a cancellation or billing failure that happens while the app
/// is closed never reaches the server any other way.
export async function handleAppleNotification(req: Request, env: Env): Promise<Response> {
  if (!isSubscriptionsEnabled(env)) return subscriptionsDisabledResponse();

  // Keyed on the caller IP: the request carries no tenant, and verifying a
  // chain is real CPU. Apple's own volume is nowhere near this.
  const ip = req.headers.get("cf-connecting-ip")?.trim() || "unknown";
  const limited = await enforceRateLimits(env, [
    { policy: "appleNotificationIpHour", key: `ip:${ip}` },
  ]);
  if (limited) return limited;

  let body: { signedPayload?: unknown };
  try {
    body = (await parseJson(req, RequestBodyLimits.appleNotification)) as {
      signedPayload?: unknown;
    };
  } catch {
    return badRequest("missing JSON body");
  }
  if (typeof body?.signedPayload !== "string") {
    return badRequest("signedPayload is required");
  }

  let payload: Record<string, unknown>;
  try {
    payload = await verifyAppleJws(body.signedPayload, { trustedRootDer: APPLE_ROOT_CA_G3_DER });
  } catch (err) {
    console.warn("apple_notification.verification_failed", {
      error: err instanceof Error ? err.message : String(err),
      // The payload is unverified by definition here; logging the claimed type
      // is what makes a run of failures diagnosable at all.
      claimedType: decodeAppleJwsPayloadUnverified(body.signedPayload)?.notificationType,
    });
    return json({ error: "notification failed verification" }, 401);
  }

  const notificationType = typeof payload.notificationType === "string"
    ? payload.notificationType
    : "unknown";
  const data = payload.data;
  const signedTransaction =
    data && typeof data === "object" && typeof (data as Record<string, unknown>).signedTransactionInfo === "string"
      ? ((data as Record<string, unknown>).signedTransactionInfo as string)
      : null;

  if (!signedTransaction) {
    // CONSUMPTION_REQUEST and friends carry no transaction. Acknowledge them:
    // a non-2xx makes Apple retry a notification we will never act on.
    return json({ ok: true, notificationType, applied: false });
  }

  try {
    const transaction = await verifyTransaction(env, signedTransaction);
    // No tenant: a notification proves a purchase changed, not who owns it. An
    // unclaimed row is adopted the next time that account's app verifies.
    await recordTransaction(env, transaction);
    await applyRenewalInfo(env, payload, transaction.originalTransactionId, notificationType);
    return json({ ok: true, notificationType, applied: true });
  } catch (err) {
    if (err instanceof SubscriptionRejected) {
      // Verified as Apple's, but not ours to act on — another app's bundle, or
      // a sandbox notification reaching a production deployment. 200 so Apple
      // stops retrying something that will never be accepted.
      console.warn("apple_notification.rejected", { notificationType, reason: err.message });
      return json({ ok: true, notificationType, applied: false });
    }
    throw err;
  }
}

/// Renewal info carries the two things a transaction does not: whether the
/// subscription is set to renew, and Apple's own billing grace period.
async function applyRenewalInfo(
  env: Env,
  payload: Record<string, unknown>,
  originalTransactionId: string,
  notificationType: string,
): Promise<void> {
  const data = payload.data;
  const signedRenewalInfo =
    data && typeof data === "object" && typeof (data as Record<string, unknown>).signedRenewalInfo === "string"
      ? ((data as Record<string, unknown>).signedRenewalInfo as string)
      : null;
  if (!signedRenewalInfo) return;

  let renewal: Record<string, unknown>;
  try {
    renewal = await verifyAppleJws(signedRenewalInfo, { trustedRootDer: APPLE_ROOT_CA_G3_DER });
  } catch {
    // The transaction is already stored and is what entitlement rests on.
    // Renewal info only sharpens the picture, so a failure here is not worth
    // discarding a verified transaction over.
    console.warn("apple_notification.renewal_info_unverified", { notificationType });
    return;
  }

  const autoRenew = renewal.autoRenewStatus === 1 ? 1 : 0;
  const graceExpires = typeof renewal.gracePeriodExpiresDate === "number"
    ? renewal.gracePeriodExpiresDate
    : null;

  await env.ZW_DB.prepare(
    `UPDATE subscriptions
     SET auto_renew = ?, grace_expires_at_ms = ?, updated_at = ?
     WHERE original_transaction_id = ?`,
  )
    .bind(autoRenew, graceExpires, new Date().toISOString(), originalTransactionId)
    .run();
}
