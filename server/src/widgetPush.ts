import type { Env, WidgetReloadQueueMessage } from "./types";
import type { ApnsResult } from "./apns";
import { sendWidgetReloadPush } from "./apns";
import * as storage from "./storage";
import { isSharingEnabled, listAcceptedShares } from "./shares";

export interface WidgetPushTarget {
  token: string;
  tenantIds: string[];
}

export interface WidgetPushDeliveryResult extends ApnsResult {
  attempts: number;
}

const MAX_ATTEMPTS = 3;
const RETRY_DELAYS_MS = [250, 1_000];
const MAX_RETRY_AFTER_MS = 5_000;
// Reload allowance for one widget, as a token bucket.
//
// Apple budgets WidgetKit reloads per widget instance — "a daily budget
// typically includes from 40 to 70 refreshes" for a widget someone views often
// — and pushes draw on the same budget as the widget's own periodic refreshes.
// So the two compete, and the split between them is a choice.
//
// The device backs its timeline off to four hours once it can see pushes
// arriving (`WidgetRefreshPolicy`), which spends about 6 reloads a day on
// polling rather than the 24 a flat hourly interval would. That freed room is
// what this spends: a sustained 48 keeps the total near 54, inside Apple's
// band, with the overwhelming majority going to reloads that carry news.
//
// A bucket rather than a quota, because a quota starves. Forty pushes five
// minutes apart spends a day in three hours and twenty minutes and leaves the
// widget dark for the next twenty — worse than the flat interval it replaced.
// Refilling continuously means a widget always regains a push after a quiet
// stretch, and the cap bounds what a burst can spend at once.
export const WIDGET_PUSH_BURST = 6;

// One push per 30 minutes sustained, which is 48 a day. With a full bucket a
// day tops out near 54.
export const WIDGET_PUSH_REFILL_SECONDS = 30 * 60;

// The shortest gap between two pushes to the same widget, whatever the bucket
// holds. Apple asks for at least five minutes between timeline entries and this
// matches it; it is also what makes a burst of publishes coalesce into one
// reload instead of each earning its own.
export const WIDGET_PUSH_MIN_SPACING_SECONDS = 5 * 60;
const TRANSIENT_QUEUE_RETRY_SECONDS = 5 * 60;
const DEAD_TOKEN_REASONS = new Set([
  "BadDeviceToken",
  "DeviceTokenNotForTopic",
  "ExpiredToken",
  "Unregistered",
]);

export function widgetPushApnsDiagnosticsEnabled(env: Env): boolean {
  return env.WIDGET_PUSH_APNS_DIAGNOSTICS === "true";
}

export async function collectWidgetPushTargetsForCard(
  env: Env,
  ownerTenantId: string,
  cardId: string,
): Promise<WidgetPushTarget[]> {
  return collectWidgetPushTargetsForCards(env, ownerTenantId, [cardId]);
}

/// Which push tokens should be reloaded because these cards changed.
///
/// A tenant's widget subscriptions are read once for the whole snapshot rather
/// than once per card. The query behind them names no card — which cards a
/// token wants lives in JSON on the row — so asking per card re-ran the same
/// tenant-wide scan every time: a ten-card batch upsert issued ten identical
/// reads. Only the share lookup is genuinely per card, because a card can be
/// shared with tenants the others are not.
export async function collectWidgetPushTargetsForCards(
  env: Env,
  ownerTenantId: string,
  cardIds: string[],
): Promise<WidgetPushTarget[]> {
  const uniqueCardIds = [...new Set(cardIds)];

  // Which tenants care about each card: always the owner, plus anyone holding
  // an accepted share of that specific card.
  const tenantIdsByCard = new Map<string, string[]>();
  const shareLookups = isSharingEnabled(env)
    ? await Promise.all(
      uniqueCardIds.map((cardId) => listAcceptedShares(env, ownerTenantId, "card", cardId)),
    )
    : [];
  for (const [index, cardId] of uniqueCardIds.entries()) {
    const recipients = (shareLookups[index] ?? [])
      .map((share) => share.recipientTenantId)
      .filter((tenantId): tenantId is string => Boolean(tenantId));
    tenantIdsByCard.set(cardId, [...new Set([ownerTenantId, ...recipients])]);
  }

  const uniqueTenantIds = [...new Set([...tenantIdsByCard.values()].flat())];
  const subscriptionsByTenant = new Map(
    await Promise.all(
      uniqueTenantIds.map(async (tenantId) =>
        [tenantId, await storage.listWidgetTokenSubscriptions(env, tenantId)] as const,
      ),
    ),
  );

  const targets = new Map<string, Set<string>>();
  for (const cardId of uniqueCardIds) {
    for (const tenantId of tenantIdsByCard.get(cardId) ?? []) {
      for (const subscription of subscriptionsByTenant.get(tenantId) ?? []) {
        if (!storage.subscriptionCoversCard(subscription, cardId)) continue;
        const tenants = targets.get(subscription.token) ?? new Set<string>();
        tenants.add(tenantId);
        targets.set(subscription.token, tenants);
      }
    }
  }
  return [...targets].map(([token, tenants]) => ({
    token,
    tenantIds: [...tenants],
  }));
}

/// Takes this widget's next push slot, or reports that it has none right now.
///
/// One statement, because the read and the write have to be the same act: two
/// publishes landing together would otherwise both see a free slot and both
/// spend it. The `WHERE` carries both rules — minimum spacing since the last
/// push, and budget left in the current rolling day — and the `CASE` arms roll
/// the day over when the previous one has expired.
export async function claimWidgetPushWindow(
  env: Env,
  token: string,
  nowSeconds = Math.floor(Date.now() / 1_000),
): Promise<boolean> {
  // Anonymous `?` placeholders, with every value bound once per appearance.
  // Numbered `?NNN` would read better for a statement that repeats five values
  // a dozen times, and D1 does document support for them — this is the plainer
  // form rather than the correct one, chosen because a claim that silently
  // returns false stops every widget on the account from reloading and logs
  // nothing, so the binding is a bad place to be clever.
  const result = await env.ZW_DB.prepare(
    `INSERT INTO widget_push_cadence (token, last_sent_at, allowance)
     VALUES (?, ?, ? - 1)
     ON CONFLICT(token) DO UPDATE SET
       allowance = MIN(
         ?,
         widget_push_cadence.allowance
           + (? - widget_push_cadence.last_sent_at) / CAST(? AS REAL)
       ) - 1,
       last_sent_at = ?
     WHERE widget_push_cadence.last_sent_at <= ? - ?
       AND MIN(
         ?,
         widget_push_cadence.allowance
           + (? - widget_push_cadence.last_sent_at) / CAST(? AS REAL)
       ) >= 1`,
  )
    .bind(
      token,                              // VALUES token
      nowSeconds,                         // VALUES last_sent_at
      WIDGET_PUSH_BURST,                  // VALUES allowance = burst - 1
      WIDGET_PUSH_BURST,                  // SET     MIN cap
      nowSeconds,                         // SET     elapsed
      WIDGET_PUSH_REFILL_SECONDS,         // SET     refill
      nowSeconds,                         // SET     last_sent_at
      nowSeconds,                         // WHERE   spacing: now
      WIDGET_PUSH_MIN_SPACING_SECONDS,    // WHERE   spacing: gap
      WIDGET_PUSH_BURST,                  // WHERE   MIN cap
      nowSeconds,                         // WHERE   elapsed
      WIDGET_PUSH_REFILL_SECONDS,         // WHERE   refill
    )
    .run();
  return Number(result.meta.changes ?? 0) > 0;
}

/// Seconds until this widget could be pushed again, from a stored row.
export function widgetPushWait(
  row: { last_sent_at: number; allowance: number },
  nowSeconds: number,
): number {
  const elapsed = nowSeconds - Number(row.last_sent_at);
  const spacing = Math.max(0, WIDGET_PUSH_MIN_SPACING_SECONDS - elapsed);
  const allowance = Math.min(
    WIDGET_PUSH_BURST,
    Number(row.allowance) + elapsed / WIDGET_PUSH_REFILL_SECONDS,
  );
  if (allowance >= 1) return spacing;
  // Short of a whole push: wait for the bucket to finish refilling one.
  const refill = Math.ceil((1 - Number(row.allowance)) * WIDGET_PUSH_REFILL_SECONDS - elapsed);
  return Math.max(spacing, Math.max(0, refill));
}

export interface PendingWidgetReload {
  tenantId: string;
  generation: number;
  queuedAt: number;
}

export async function enqueuePendingWidgetReload(
  env: Env,
  tenantId: string,
  nowSeconds = Math.floor(Date.now() / 1_000),
): Promise<void> {
  const existing = await getPendingWidgetReload(env, tenantId);
  if (!existing && env.WIDGET_RELOAD_QUEUE) {
    const delaySeconds = await secondsUntilWidgetPushWindow(env, tenantId, nowSeconds);
    await env.WIDGET_RELOAD_QUEUE.send(
      { tenantId },
      { delaySeconds: Math.max(1, delaySeconds) },
    );
  }
  await env.ZW_DB.prepare(
    `INSERT INTO widget_push_pending (tenant_id, generation, queued_at)
     VALUES (?, 1, ?)
     ON CONFLICT(tenant_id) DO UPDATE SET
       generation = widget_push_pending.generation + 1,
       queued_at = excluded.queued_at`,
  )
    .bind(tenantId, nowSeconds)
    .run();
}

export async function getPendingWidgetReload(
  env: Env,
  tenantId: string,
): Promise<PendingWidgetReload | null> {
  const row = await env.ZW_DB.prepare(
    `SELECT tenant_id, generation, queued_at
     FROM widget_push_pending
     WHERE tenant_id = ?`,
  )
    .bind(tenantId)
    .first<{ tenant_id: string; generation: number; queued_at: number }>();
  return row ? pendingFromRow(row) : null;
}

/// How long until *any* of this tenant's widgets can be pushed again.
///
/// The soonest, not the latest: a queued reload should wake as soon as it can
/// deliver to something. Widgets still waiting keep their pending row and are
/// picked up on a later pass.
export async function secondsUntilWidgetPushWindow(
  env: Env,
  tenantId: string,
  nowSeconds = Math.floor(Date.now() / 1_000),
): Promise<number> {
  const tokens = [...new Set(await storage.listWidgetTokens(env, tenantId))];
  if (tokens.length === 0) return 0;
  const rows = await env.ZW_DB.prepare(
    `SELECT token, last_sent_at, allowance
     FROM widget_push_cadence
     WHERE token IN (${tokens.map(() => "?").join(", ")})`,
  )
    .bind(...tokens)
    .all<{ token: string; last_sent_at: number; allowance: number }>();

  const known = new Map(rows.results.map((row) => [row.token, row]));
  let soonest = Number.POSITIVE_INFINITY;
  for (const token of tokens) {
    const row = known.get(token);
    // Never pushed, so nothing is holding it back.
    if (!row) return 0;
    soonest = Math.min(soonest, widgetPushWait(row, nowSeconds));
    if (soonest === 0) return 0;
  }
  return Number.isFinite(soonest) ? soonest : 0;
}

export interface PendingWidgetReloadOutcome {
  delivered: boolean;
  retryAfterSeconds?: number;
}

export async function processPendingWidgetReload(
  env: Env,
  message: WidgetReloadQueueMessage,
  options: {
    nowSeconds?: number;
    sender?: (env: Env, token: string) => Promise<ApnsResult>;
    sleep?: (ms: number) => Promise<void>;
  } = {},
): Promise<PendingWidgetReloadOutcome> {
  const nowSeconds = options.nowSeconds ?? Math.floor(Date.now() / 1_000);
  const pending = await getPendingWidgetReload(env, message.tenantId);
  if (!pending) return { delivered: false };

  const delaySeconds = await secondsUntilWidgetPushWindow(
    env,
    pending.tenantId,
    nowSeconds,
  );
  if (delaySeconds > 0) {
    return { delivered: false, retryAfterSeconds: delaySeconds };
  }

  const tokens = [...new Set(await storage.listWidgetTokens(env, pending.tenantId))];
  if (tokens.length === 0) {
    await deletePendingWidgetReload(env, pending);
    return { delivered: false };
  }
  // Each widget has its own allowance, so this claims per token rather than
  // for the tenant. A device with two widgets where only one has a slot free
  // gets that one reloaded now and the other on a later pass.
  const claimed: string[] = [];
  for (const token of tokens) {
    if (await claimWidgetPushWindow(env, token, nowSeconds)) claimed.push(token);
  }
  if (claimed.length === 0) {
    return {
      delivered: false,
      retryAfterSeconds: Math.max(
        1,
        await secondsUntilWidgetPushWindow(env, pending.tenantId, nowSeconds),
      ),
    };
  }
  const targets = claimed.map((token) => ({ token, tenantIds: [pending.tenantId] }));
  const results = await deliverWidgetReloads(env, targets, options);
  logDeliverySummary(
    { tenantId: pending.tenantId, cardIds: [] },
    targets.length,
    results,
  );
  if (hasRetryableFailure(results)) {
    return { delivered: false, retryAfterSeconds: TRANSIENT_QUEUE_RETRY_SECONDS };
  }
  // Any widget that had no slot still needs one, so the pending row stays and
  // the message comes back when the soonest of them opens.
  if (claimed.length < tokens.length) {
    return {
      delivered: true,
      retryAfterSeconds: Math.max(
        1,
        await secondsUntilWidgetPushWindow(env, pending.tenantId, nowSeconds),
      ),
    };
  }
  const cleared = await deletePendingWidgetReload(env, pending);
  if (!cleared) {
    return {
      delivered: true,
      retryAfterSeconds: WIDGET_PUSH_MIN_SPACING_SECONDS,
    };
  }
  return { delivered: true };
}

export async function deliverWidgetReloads(
  env: Env,
  targets: WidgetPushTarget[],
  options: {
    sender?: (env: Env, token: string) => Promise<ApnsResult>;
    sleep?: (ms: number) => Promise<void>;
  } = {},
): Promise<WidgetPushDeliveryResult[]> {
  const sender = options.sender ?? sendWidgetReloadPush;
  const wait = options.sleep ?? sleep;
  const results: WidgetPushDeliveryResult[] = [];

  // Keep concurrency bounded so one tenant with many devices doesn't create a
  // burst of simultaneous APNs subrequests from a single Worker invocation.
  for (let offset = 0; offset < targets.length; offset += 10) {
    const batch = targets.slice(offset, offset + 10);
    const delivered = await Promise.all(
      batch.map((target) => deliverOne(env, target, sender, wait)),
    );
    results.push(...delivered);
  }
  return results;
}

export function scheduleWidgetReloadForCard(
  ctx: ExecutionContext,
  env: Env,
  ownerTenantId: string,
  cardId: string,
): void {
  scheduleWidgetReloadForCards(ctx, env, ownerTenantId, [cardId]);
}

export function scheduleWidgetReloadForCards(
  ctx: ExecutionContext,
  env: Env,
  ownerTenantId: string,
  cardIds: string[],
): void {
  const context = { tenantId: ownerTenantId, cardIds: [...new Set(cardIds)] };
  const task = collectWidgetPushTargetsForCards(
    env,
    ownerTenantId,
    context.cardIds,
  ).then((targets) => deliverOrEnqueueWidgetReloads(env, targets, context));
  scheduleTask(ctx, task, context);
}

export function scheduleWidgetReloads(
  ctx: ExecutionContext,
  env: Env,
  targets: WidgetPushTarget[],
  context: { tenantId: string; cardId: string },
): void {
  const taskContext = { tenantId: context.tenantId, cardIds: [context.cardId] };
  scheduleTask(
    ctx,
    deliverOrEnqueueWidgetReloads(env, targets, taskContext),
    taskContext,
  );
}

async function deliverOrEnqueueWidgetReloads(
  env: Env,
  targets: WidgetPushTarget[],
  context: { tenantId: string; cardIds: string[] },
): Promise<void> {
  const grouped = groupTargetsByTenant(targets);
  await Promise.all(
    [...grouped.entries()].map(async ([tenantId, tenantTargets]) => {
      // If an older suppressed change is already queued, one generic reload of
      // every token for the tenant covers both it and the current change.
      const pending = await getPendingWidgetReload(env, tenantId);
      let candidates = tenantTargets;
      if (pending) {
        const tokens = [...new Set(await storage.listWidgetTokens(env, tenantId))];
        candidates = tokens.map((token) => ({ token, tenantIds: [tenantId] }));
      }

      // Per widget, not per tenant: one widget being inside its spacing window
      // must not hold back another that is ready.
      const deliveryTargets: WidgetPushTarget[] = [];
      for (const target of candidates) {
        if (await claimWidgetPushWindow(env, target.token)) deliveryTargets.push(target);
      }
      if (deliveryTargets.length === 0) {
        await enqueuePendingWidgetReload(env, tenantId);
        return;
      }
      const results = await deliverWidgetReloads(env, deliveryTargets);
      logDeliverySummary(
        { tenantId, cardIds: context.cardIds },
        deliveryTargets.length,
        results,
      );
      if (hasRetryableFailure(results) || deliveryTargets.length < candidates.length) {
        await enqueuePendingWidgetReload(env, tenantId);
      } else if (pending) {
        await deletePendingWidgetReload(env, pending);
      }
    }),
  );
}

function groupTargetsByTenant(
  targets: WidgetPushTarget[],
): Map<string, WidgetPushTarget[]> {
  const grouped = new Map<string, Map<string, WidgetPushTarget>>();
  for (const target of targets) {
    for (const tenantId of target.tenantIds) {
      const byToken = grouped.get(tenantId) ?? new Map<string, WidgetPushTarget>();
      byToken.set(target.token, { token: target.token, tenantIds: [tenantId] });
      grouped.set(tenantId, byToken);
    }
  }
  return new Map(
    [...grouped].map(([tenantId, byToken]) => [tenantId, [...byToken.values()]]),
  );
}

async function deletePendingWidgetReload(
  env: Env,
  pending: PendingWidgetReload,
): Promise<boolean> {
  const result = await env.ZW_DB.prepare(
    `DELETE FROM widget_push_pending
     WHERE tenant_id = ? AND generation = ?`,
  )
    .bind(pending.tenantId, pending.generation)
    .run();
  return Number(result.meta.changes ?? 0) > 0;
}

function pendingFromRow(row: {
  tenant_id: string;
  generation: number;
  queued_at: number;
}): PendingWidgetReload {
  return {
    tenantId: row.tenant_id,
    generation: Number(row.generation),
    queuedAt: Number(row.queued_at),
  };
}

function hasRetryableFailure(results: WidgetPushDeliveryResult[]): boolean {
  return results.some(isTransient);
}

function scheduleTask(
  ctx: ExecutionContext,
  task: Promise<void>,
  context: { tenantId: string; cardIds: string[] },
): void {
  const guarded = task.catch((error) => {
    console.error("widget push fan-out failed", {
      ...context,
      error: error instanceof Error ? error.message : String(error),
    });
  });
  const waitUntil = (ctx as Partial<ExecutionContext> | undefined)?.waitUntil;
  if (typeof waitUntil === "function") {
    waitUntil.call(ctx, guarded);
  } else {
    void guarded;
  }
}

function logDeliverySummary(
  context: { tenantId: string; cardIds: string[] },
  targetCount: number,
  results: WidgetPushDeliveryResult[],
): void {
  const accepted = results.filter((result) => result.status === 200).length;
  const skipped = results.filter(
    (result) => result.status === 0 && result.reason === "apns-not-configured",
  ).length;
  const failed = results.length - accepted - skipped;
  const summary = {
    event: "widget.push.summary",
    tenantId: context.tenantId,
    cardCount: context.cardIds.length,
    targetCount,
    accepted,
    skipped,
    failed,
    attempts: results.reduce((total, result) => total + result.attempts, 0),
  };
  if (failed > 0) {
    console.warn("widget push delivery incomplete", summary);
  } else if (accepted > 0 && sampleSuccess(context.tenantId)) {
    console.log("widget push delivery sampled", summary);
  }
}

function sampleSuccess(tenantId: string): boolean {
  const hour = Math.floor(Date.now() / (60 * 60 * 1_000));
  let hash = hour;
  for (const char of tenantId) hash = ((hash * 31) + char.charCodeAt(0)) | 0;
  return Math.abs(hash) % 20 === 0;
}

async function deliverOne(
  env: Env,
  target: WidgetPushTarget,
  sender: (env: Env, token: string) => Promise<ApnsResult>,
  wait: (ms: number) => Promise<void>,
): Promise<WidgetPushDeliveryResult> {
  let result: ApnsResult = { status: 0, reason: "network-error" };
  let attempts = 0;
  for (attempts = 1; attempts <= MAX_ATTEMPTS; attempts++) {
    try {
      result = await sender(env, target.token);
    } catch (error) {
      result = {
        status: 0,
        reason: error instanceof Error ? error.message : "network-error",
      };
    }
    if (!isTransient(result) || attempts === MAX_ATTEMPTS) break;
    await wait(retryDelay(result, attempts));
  }

  if (widgetPushApnsDiagnosticsEnabled(env)) {
    try {
      await storage.putWidgetPushDeliveryDiagnostic(env, target.token, {
        status: result.status,
        reason: result.reason,
        apnsId: result.apnsId ?? undefined,
        attempts,
      });
    } catch (error) {
      // Diagnostics must never turn an accepted APNs delivery into a failed
      // publish or prevent permanent-token cleanup.
      console.error("widget push diagnostic write failed", {
        status: result.status,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }

  if (DEAD_TOKEN_REASONS.has(result.reason ?? "")) {
    await Promise.all(
      target.tenantIds.map((tenantId) =>
        storage.deleteWidgetTokenByValue(env, tenantId, target.token),
      ),
    );
  } else if (
    result.status !== 200 &&
    !(result.status === 0 && result.reason === "apns-not-configured")
  ) {
    console.log("widget push failed", {
      tenantIds: target.tenantIds,
      status: result.status,
      reason: result.reason,
      apnsId: result.apnsId,
      attempts,
    });
  }
  return { ...result, attempts };
}

function isTransient(result: ApnsResult): boolean {
  return (
    (result.status === 0 && result.reason !== "apns-not-configured") ||
    result.status === 429 ||
    (result.status >= 500 && result.status <= 599)
  );
}

function retryDelay(result: ApnsResult, attempts: number): number {
  if (result.status === 429 && result.retryAfterSeconds !== undefined) {
    return Math.min(result.retryAfterSeconds * 1_000, MAX_RETRY_AFTER_MS);
  }
  return RETRY_DELAYS_MS[attempts - 1] ?? 0;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
