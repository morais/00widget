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
// Apple budgets WidgetKit reloads over a rolling day. Keeping the server below
// two pushes/hour leaves room for timeline and foreground-triggered reloads.
export const MIN_PUSH_INTERVAL_SECONDS = 30 * 60;
const TRANSIENT_QUEUE_RETRY_SECONDS = 5 * 60;
const DEAD_TOKEN_REASONS = new Set([
  "BadDeviceToken",
  "DeviceTokenNotForTopic",
  "ExpiredToken",
  "Unregistered",
]);

export async function collectWidgetPushTargetsForCard(
  env: Env,
  ownerTenantId: string,
  cardId: string,
): Promise<WidgetPushTarget[]> {
  const tenantIds = [ownerTenantId];
  if (isSharingEnabled(env)) {
    const accepted = await listAcceptedShares(env, ownerTenantId, "card", cardId);
    for (const share of accepted) {
      if (share.recipientTenantId) tenantIds.push(share.recipientTenantId);
    }
  }

  const targets = new Map<string, Set<string>>();
  const uniqueTenantIds = [...new Set(tenantIds)];
  const tokenLists = await Promise.all(
    uniqueTenantIds.map((tenantId) =>
      storage.listWidgetTokensForCard(env, tenantId, cardId),
    ),
  );
  for (const [index, tenantId] of uniqueTenantIds.entries()) {
    const tokens = tokenLists[index];
    for (const token of tokens) {
      const tenants = targets.get(token) ?? new Set<string>();
      tenants.add(tenantId);
      targets.set(token, tenants);
    }
  }
  return [...targets].map(([token, tenants]) => ({
    token,
    tenantIds: [...tenants],
  }));
}

export async function collectWidgetPushTargetsForCards(
  env: Env,
  ownerTenantId: string,
  cardIds: string[],
): Promise<WidgetPushTarget[]> {
  const collected = await Promise.all(
    [...new Set(cardIds)].map((cardId) =>
      collectWidgetPushTargetsForCard(env, ownerTenantId, cardId),
    ),
  );
  const targets = new Map<string, Set<string>>();
  for (const entries of collected) {
    for (const entry of entries) {
      const tenants = targets.get(entry.token) ?? new Set<string>();
      for (const tenantId of entry.tenantIds) tenants.add(tenantId);
      targets.set(entry.token, tenants);
    }
  }
  return [...targets].map(([token, tenantIds]) => ({
    token,
    tenantIds: [...tenantIds],
  }));
}

export async function claimWidgetPushWindow(
  env: Env,
  tenantId: string,
  nowSeconds = Math.floor(Date.now() / 1_000),
): Promise<boolean> {
  const result = await env.ZW_DB.prepare(
    `INSERT INTO widget_push_cadence (tenant_id, last_sent_at)
     VALUES (?, ?)
     ON CONFLICT(tenant_id) DO UPDATE SET last_sent_at = excluded.last_sent_at
     WHERE widget_push_cadence.last_sent_at <= ?`,
  )
    .bind(tenantId, nowSeconds, nowSeconds - MIN_PUSH_INTERVAL_SECONDS)
    .run();
  return Number(result.meta.changes ?? 0) > 0;
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

export async function secondsUntilWidgetPushWindow(
  env: Env,
  tenantId: string,
  nowSeconds = Math.floor(Date.now() / 1_000),
): Promise<number> {
  const row = await env.ZW_DB.prepare(
    `SELECT last_sent_at
     FROM widget_push_cadence
     WHERE tenant_id = ?`,
  )
    .bind(tenantId)
    .first<{ last_sent_at: number }>();
  if (!row) return 0;
  return Math.max(0, Number(row.last_sent_at) + MIN_PUSH_INTERVAL_SECONDS - nowSeconds);
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
  if (!(await claimWidgetPushWindow(env, pending.tenantId, nowSeconds))) {
    return {
      delivered: false,
      retryAfterSeconds: Math.max(
        1,
        await secondsUntilWidgetPushWindow(env, pending.tenantId, nowSeconds),
      ),
    };
  }
  const targets = tokens.map((token) => ({ token, tenantIds: [pending.tenantId] }));
  const results = await deliverWidgetReloads(env, targets, options);
  logDeliverySummary(
    { tenantId: pending.tenantId, cardIds: [] },
    targets.length,
    results,
  );
  if (hasRetryableFailure(results)) {
    return { delivered: false, retryAfterSeconds: TRANSIENT_QUEUE_RETRY_SECONDS };
  }
  const cleared = await deletePendingWidgetReload(env, pending);
  if (!cleared) {
    return {
      delivered: true,
      retryAfterSeconds: MIN_PUSH_INTERVAL_SECONDS,
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
      const claimed = await claimWidgetPushWindow(env, tenantId);
      if (!claimed) {
        await enqueuePendingWidgetReload(env, tenantId);
        return;
      }

      // If an older suppressed change is already queued, one generic reload of
      // every token for the tenant covers both it and the current change.
      const pending = await getPendingWidgetReload(env, tenantId);
      let deliveryTargets = tenantTargets;
      if (pending) {
        const tokens = [...new Set(await storage.listWidgetTokens(env, tenantId))];
        deliveryTargets = tokens.map((token) => ({ token, tenantIds: [tenantId] }));
      }
      const results = await deliverWidgetReloads(env, deliveryTargets);
      logDeliverySummary(
        { tenantId, cardIds: context.cardIds },
        deliveryTargets.length,
        results,
      );
      if (hasRetryableFailure(results)) {
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
