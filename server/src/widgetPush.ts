import type { Env } from "./types";
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
const MIN_PUSH_INTERVAL_SECONDS = 30 * 60;
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
  ).then(async (targets) => {
    // Don't consume a tenant's cadence window before their first widget has
    // registered; the next card update should be able to refresh it.
    if (targets.length === 0) return;
    const claimed = await claimWidgetPushWindow(env, ownerTenantId);
    if (!claimed) return;
    const results = await deliverWidgetReloads(env, targets);
    logDeliverySummary(context, targets.length, results);
  });
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
    deliverWidgetReloads(env, targets).then((results) => {
      logDeliverySummary(taskContext, targets.length, results);
    }),
    taskContext,
  );
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
