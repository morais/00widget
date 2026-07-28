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
  const task = collectWidgetPushTargetsForCard(env, ownerTenantId, cardId)
    .then((targets) => deliverWidgetReloads(env, targets))
    .then(() => undefined)
    .catch((error) => {
      console.error("widget push fan-out failed", {
        tenantId: ownerTenantId,
        cardId,
        error: error instanceof Error ? error.message : String(error),
      });
    });
  const waitUntil = (ctx as Partial<ExecutionContext> | undefined)?.waitUntil;
  if (typeof waitUntil === "function") {
    waitUntil.call(ctx, task);
  } else {
    void task;
  }
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
    await wait(RETRY_DELAYS_MS[attempts - 1] ?? 0);
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
    result.status === 500 ||
    result.status === 503
  );
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
