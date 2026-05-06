import type { ActionDefinition, DashboardCard, Env } from "./types";
import { DashboardCardSchema, RunActionSchema, WebhookIntegrationSchema } from "./types";
import * as storage from "./storage";
import { sendWidgetReloadPush } from "./apns";
import { json, badRequest, notFound } from "./http";
import type { AuthContext } from "./auth";
import { parseJson } from "./cards";

const WEBHOOK_ATTEMPTS = 3;
const RETRY_DELAYS_MS = [250, 1000];
const WEBHOOK_TIMEOUT_MS = 5_000;
const MAX_WEBHOOK_RESPONSE_BYTES = 64 * 1024;

export async function getWebhookIntegration(
  _req: Request,
  env: Env,
  auth: AuthContext,
): Promise<Response> {
  const integration = await storage.getWebhookIntegration(env, auth.tenantId);
  if (!integration) return notFound();
  return json({
    url: integration.url,
    createdAt: integration.createdAt,
    updatedAt: integration.updatedAt,
  });
}

export async function putWebhookIntegration(
  req: Request,
  env: Env,
  auth: AuthContext,
): Promise<Response> {
  const body = await parseJson(req);
  const parsed = WebhookIntegrationSchema.safeParse(body);
  if (!parsed.success) return badRequest(`validation failed: ${parsed.error.message}`);

  const now = new Date().toISOString();
  const existing = await storage.getWebhookIntegration(env, auth.tenantId);
  const signingSecret =
    !existing || parsed.data.rotateSecret ? randomSecret() : existing.signingSecret;
  const record: storage.WebhookIntegrationRecord = {
    url: parsed.data.url,
    signingSecret,
    createdAt: existing?.createdAt ?? now,
    updatedAt: now,
  };
  await storage.putWebhookIntegration(env, auth.tenantId, auth.apiKeyHash, record);
  return json({
    url: record.url,
    signingSecret,
    createdAt: record.createdAt,
    updatedAt: record.updatedAt,
  });
}

export async function deleteWebhookIntegration(
  _req: Request,
  env: Env,
  auth: AuthContext,
): Promise<Response> {
  await storage.deleteWebhookIntegration(env, auth.tenantId);
  return json({ ok: true });
}

export async function runAction(
  req: Request,
  env: Env,
  auth: AuthContext,
  actionId: string,
): Promise<Response> {
  const body = await parseJson(req);
  const parsed = RunActionSchema.safeParse(body ?? {});
  if (!parsed.success) return badRequest(`validation failed: ${parsed.error.message}`);

  const integration = await storage.getWebhookIntegration(env, auth.tenantId);
  if (!integration) {
    return json({ error: "webhook integration not configured" }, 409);
  }

  const resolved = await resolveAction(env, auth.tenantId, actionId, parsed.data.context?.cardId);
  if (!resolved) return notFound();
  if (isWidgetSource(parsed.data.source)) {
    if (!parsed.data.context?.cardId) {
      return json({ error: "widget actions require card context" }, 403);
    }
    if (!isSafeFromWidget(resolved.action)) {
      return json({ error: "action is not safe to run from widgets" }, 403);
    }
  }

  const deliveryId = crypto.randomUUID();
  const timestamp = new Date().toISOString();
  const payload = {
    deliveryId,
    timestamp,
    source: parsed.data.source,
    accountId: auth.tenantId,
    action: {
      id: actionId,
      label: resolved.action.label,
      payload: resolved.action.payload ?? {},
    },
    context: {
      cardId: resolved.card.id,
      cardTitle: resolved.card.title,
    },
  };
  const rawBody = JSON.stringify(payload);
  const timestampHeader = String(Math.floor(Date.now() / 1000));
  const signature = await signWebhookBody(integration.signingSecret, timestampHeader, rawBody);

  const result = await deliverWebhook(integration.url, {
    rawBody,
    timestamp: timestampHeader,
    signature,
    deliveryId,
  });
  if (!result.ok) {
    return json(
      {
        error: "webhook delivery failed",
        actionId,
        deliveryId,
        status: result.status,
        attempts: result.attempts,
      },
      502,
    );
  }

  let updatedCard = false;
  if (result.responseBody) {
    updatedCard = await maybeUpsertResponseCard(env, auth, result.responseBody);
  }

  return json({
    ok: true,
    actionId,
    source: parsed.data.source,
    deliveryId,
    webhookStatus: result.status,
    updatedCard,
  });
}

async function resolveAction(
  env: Env,
  tenantId: string,
  actionId: string,
  cardId?: string,
): Promise<{ card: DashboardCard; action: ActionDefinition } | null> {
  const cards = cardId
    ? [await storage.getCard(env, tenantId, cardId)].filter((card): card is DashboardCard => Boolean(card))
    : await storage.listCards(env, tenantId);
  for (const card of cards) {
    const action = card.actions?.find((candidate) => candidate.id === actionId);
    if (action) return { card, action };
  }
  return null;
}

async function deliverWebhook(
  url: string,
  opts: {
    rawBody: string;
    timestamp: string;
    signature: string;
    deliveryId: string;
  },
): Promise<{ ok: boolean; status: number; attempts: number; responseBody?: unknown }> {
  let lastStatus = 0;
  for (let attempt = 1; attempt <= WEBHOOK_ATTEMPTS; attempt++) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), WEBHOOK_TIMEOUT_MS);
    try {
      const res = await fetch(url, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-00widget-timestamp": opts.timestamp,
          "x-00widget-signature": `sha256=${opts.signature}`,
          "x-00widget-delivery": opts.deliveryId,
        },
        body: opts.rawBody,
        signal: controller.signal,
      });
      clearTimeout(timeout);
      lastStatus = res.status;
      if (res.status >= 200 && res.status < 300) {
        return {
          ok: true,
          status: res.status,
          attempts: attempt,
          responseBody: await readJsonIfPresent(res, MAX_WEBHOOK_RESPONSE_BYTES),
        };
      }
      if (res.status < 500 || attempt === WEBHOOK_ATTEMPTS) {
        return { ok: false, status: res.status, attempts: attempt };
      }
    } catch {
      clearTimeout(timeout);
      lastStatus = 0;
      if (attempt === WEBHOOK_ATTEMPTS) return { ok: false, status: 0, attempts: attempt };
    }
    await sleep(RETRY_DELAYS_MS[attempt - 1] ?? 0);
  }
  return { ok: false, status: lastStatus, attempts: WEBHOOK_ATTEMPTS };
}

function isWidgetSource(source: string): boolean {
  return source.trim().toLowerCase() === "widget";
}

function isSafeFromWidget(action: ActionDefinition): boolean {
  return (action.role ?? "normal") === "normal" && action.confirm !== true;
}

async function maybeUpsertResponseCard(
  env: Env,
  auth: AuthContext,
  responseBody: unknown,
): Promise<boolean> {
  const candidate =
    responseBody && typeof responseBody === "object" && "card" in responseBody
      ? (responseBody as { card: unknown }).card
      : responseBody;
  const parsed = DashboardCardSchema.safeParse(candidate);
  if (!parsed.success) return false;
  const card = {
    ...parsed.data,
    updatedAt: parsed.data.updatedAt ?? new Date().toISOString(),
  };
  await storage.putCard(env, auth.tenantId, auth.apiKeyHash, card);
  const tokens = await listCardWidgetTokens(env, auth.tenantId);
  for (const token of tokens) {
    const result = await sendWidgetReloadPush(env, token);
    if (result.status !== 200 && result.status !== 0) {
      console.log("widget push failed", { status: result.status, reason: result.reason });
    }
  }
  return true;
}

async function readJsonIfPresent(
  res: Response,
  maxBytes: number,
): Promise<unknown | undefined> {
  const text = await readTextUpTo(res, maxBytes);
  if (!text.trim()) return undefined;
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}

async function readTextUpTo(res: Response, maxBytes: number): Promise<string> {
  if (!res.body) return "";
  const reader = res.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done || !value) break;
    total += value.byteLength;
    if (total > maxBytes) {
      await reader.cancel();
      return "";
    }
    chunks.push(value);
  }
  const body = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder().decode(body);
}

async function signWebhookBody(secret: string, timestamp: string, rawBody: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(`${timestamp}.${rawBody}`),
  );
  return hex(new Uint8Array(signature));
}

function randomSecret(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return hex(bytes);
}

function hex(bytes: Uint8Array): string {
  return [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function listCardWidgetTokens(env: Env, tenantId: string): Promise<string[]> {
  const widgetKinds = ["ZeroZeroWidgetCardWidget", "ZeroZeroWidgetCardGridWidget"];
  const nested = await Promise.all(
    widgetKinds.map((kind) => storage.listWidgetTokensForKind(env, tenantId, kind)),
  );
  return [...new Set(nested.flat())];
}
