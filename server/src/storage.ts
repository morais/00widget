import type { Env, DashboardCard, StartLiveActivity } from "./types";

export const keys = {
  card: (hash: string, id: string) => `card:${hash}:${id}`,
  cardsIndex: (hash: string) => `cards-index:${hash}`,
  device: (hash: string, deviceId: string) => `device:${hash}:${deviceId}`,
  widgetToken: (hash: string, deviceId: string, kind: string) =>
    `widget-token:${hash}:${deviceId}:${kind}`,
  activity: (hash: string, externalId: string) => `activity:${hash}:${externalId}`,
  pendingActivity: (hash: string, externalId: string) =>
    `pending-activity:${hash}:${externalId}`,
  startToken: (hash: string, deviceId: string, attributesType: string) =>
    `start-token:${hash}:${deviceId}:${attributesType}`,
};

export interface DeviceRecord {
  apnsDeviceToken?: string;
  appVersion?: string;
  platform?: string;
  updatedAt: string;
}

export interface ActivityRecord {
  pushToken: string;
  deviceId: string;
  localActivityId: string;
  kind: string;
  updatedAt: string;
  lastState?: unknown;
}

export interface PendingActivityRecord extends StartLiveActivity {
  startedAt: string;
  updatedAt: string;
}

interface JsonRow {
  json: string;
}

interface TokenRow {
  token: string;
}

function nowIso(): string {
  return new Date().toISOString();
}

function json<T>(value: T): string {
  return JSON.stringify(value);
}

function parseJson<T>(raw: string): T {
  return JSON.parse(raw) as T;
}

function db(env: Env): D1Database | undefined {
  return env.ZW_DB;
}

function legacyFallbackEnabled(env: Env): boolean {
  return env.STORAGE_LEGACY_KV_FALLBACK === "true";
}

function tenantId(apiKeyHash: string): string {
  return apiKeyHash;
}

async function listKv<T>(
  env: Env,
  prefix: string,
  parse: (key: string, raw: string) => T | null,
): Promise<T[]> {
  const out: T[] = [];
  let cursor: string | undefined;
  do {
    const page = await env.ZW_KV.list({ prefix, cursor });
    for (const k of page.keys) {
      const raw = await env.ZW_KV.get(k.name);
      if (raw == null) continue;
      const parsed = parse(k.name, raw);
      if (parsed != null) out.push(parsed);
    }
    cursor = page.list_complete ? undefined : page.cursor;
  } while (cursor);
  return out;
}

async function legacyListCards(env: Env, hash: string): Promise<DashboardCard[]> {
  return listKv(env, `card:${hash}:`, (_key, raw) => parseJson<DashboardCard>(raw));
}

async function legacyListWidgetTokens(env: Env, hash: string): Promise<string[]> {
  return listKv(env, `widget-token:${hash}:`, (_key, raw) => raw);
}

async function legacyListStartTokens(
  env: Env,
  hash: string,
  attributesType: string,
): Promise<string[]> {
  return listKv(env, `start-token:${hash}:`, (key, raw) =>
    key.endsWith(`:${attributesType}`) ? raw : null,
  );
}

async function legacyListPendingActivities(
  env: Env,
  hash: string,
): Promise<PendingActivityRecord[]> {
  return listKv(env, `pending-activity:${hash}:`, (_key, raw) =>
    parseJson<PendingActivityRecord>(raw),
  );
}

function parseScopedSuffix(key: string, prefix: string): string | null {
  return key.startsWith(prefix) ? key.slice(prefix.length) : null;
}

function splitLast(value: string): [string, string] | null {
  const i = value.lastIndexOf(":");
  if (i <= 0 || i === value.length - 1) return null;
  return [value.slice(0, i), value.slice(i + 1)];
}

async function upsertCardD1(d1: D1Database, hash: string, card: DashboardCard): Promise<void> {
  await d1
    .prepare(
      `INSERT OR REPLACE INTO cards (tenant_id, api_key_hash, id, json, updated_at)
       VALUES (?, ?, ?, ?, ?)`,
    )
    .bind(tenantId(hash), hash, card.id, json(card), card.updatedAt ?? nowIso())
    .run();
}

export async function putCard(env: Env, hash: string, card: DashboardCard): Promise<void> {
  const d1 = db(env);
  if (!d1) {
    await env.ZW_KV.put(keys.card(hash, card.id), json(card));
    return;
  }
  await upsertCardD1(d1, hash, card);
}

export async function getCard(env: Env, hash: string, id: string): Promise<DashboardCard | null> {
  const d1 = db(env);
  if (!d1) {
    const raw = await env.ZW_KV.get(keys.card(hash, id));
    return raw ? parseJson<DashboardCard>(raw) : null;
  }

  const row = await d1
    .prepare(`SELECT json FROM cards WHERE tenant_id = ? AND id = ?`)
    .bind(tenantId(hash), id)
    .first<JsonRow>();
  if (row) return parseJson<DashboardCard>(row.json);

  if (!legacyFallbackEnabled(env)) return null;
  const legacy = await env.ZW_KV.get(keys.card(hash, id));
  if (!legacy) return null;
  const card = parseJson<DashboardCard>(legacy);
  await upsertCardD1(d1, hash, card);
  return card;
}

export async function listCards(env: Env, hash: string): Promise<DashboardCard[]> {
  const d1 = db(env);
  if (!d1) return legacyListCards(env, hash);

  const rows = await d1
    .prepare(`SELECT json FROM cards WHERE tenant_id = ? ORDER BY id`)
    .bind(tenantId(hash))
    .all<JsonRow>();
  if (rows.results.length > 0) {
    return rows.results.map((row) => parseJson<DashboardCard>(row.json));
  }
  if (!legacyFallbackEnabled(env)) return [];

  const legacy = await legacyListCards(env, hash);
  for (const card of legacy) {
    await upsertCardD1(d1, hash, card);
  }
  return legacy;
}

export async function deleteCard(env: Env, hash: string, id: string): Promise<void> {
  const d1 = db(env);
  if (d1) {
    await d1
      .prepare(`DELETE FROM cards WHERE tenant_id = ? AND id = ?`)
      .bind(tenantId(hash), id)
      .run();
  }
  if (!d1 || legacyFallbackEnabled(env)) {
    await env.ZW_KV.delete(keys.card(hash, id));
    const indexRaw = await env.ZW_KV.get(keys.cardsIndex(hash));
    if (indexRaw) {
      const ids: string[] = JSON.parse(indexRaw);
      const filtered = ids.filter((x) => x !== id);
      await env.ZW_KV.put(keys.cardsIndex(hash), json(filtered));
    }
  }
}

export async function putDevice(
  env: Env,
  hash: string,
  deviceId: string,
  record: DeviceRecord,
): Promise<void> {
  const d1 = db(env);
  if (!d1) {
    await env.ZW_KV.put(keys.device(hash, deviceId), json(record));
    return;
  }
  await d1
    .prepare(
      `INSERT OR REPLACE INTO devices (tenant_id, api_key_hash, device_id, json, updated_at)
       VALUES (?, ?, ?, ?, ?)`,
    )
    .bind(tenantId(hash), hash, deviceId, json(record), record.updatedAt)
    .run();
}

export async function putWidgetToken(
  env: Env,
  hash: string,
  deviceId: string,
  widgetKind: string,
  token: string,
): Promise<void> {
  const d1 = db(env);
  if (!d1) {
    await env.ZW_KV.put(keys.widgetToken(hash, deviceId, widgetKind), token);
    return;
  }
  await d1
    .prepare(
      `INSERT OR REPLACE INTO widget_tokens
       (tenant_id, api_key_hash, device_id, widget_kind, token, updated_at)
       VALUES (?, ?, ?, ?, ?, ?)`,
    )
    .bind(tenantId(hash), hash, deviceId, widgetKind, token, nowIso())
    .run();
}

export async function listWidgetTokens(env: Env, hash: string): Promise<string[]> {
  const d1 = db(env);
  if (!d1) return legacyListWidgetTokens(env, hash);

  const rows = await d1
    .prepare(
      `SELECT token FROM widget_tokens
       WHERE tenant_id = ?
       ORDER BY device_id, widget_kind`,
    )
    .bind(tenantId(hash))
    .all<TokenRow>();
  if (rows.results.length > 0) return rows.results.map((row) => row.token);
  if (!legacyFallbackEnabled(env)) return [];

  const prefix = `widget-token:${hash}:`;
  const legacy = await listKv(env, prefix, (key, token) => {
    const suffix = parseScopedSuffix(key, prefix);
    const parts = suffix ? splitLast(suffix) : null;
    return parts ? { deviceId: parts[0], widgetKind: parts[1], token } : null;
  });
  for (const row of legacy) {
    await putWidgetToken(env, hash, row.deviceId, row.widgetKind, row.token);
  }
  return legacy.map((row) => row.token);
}

export async function putActivity(
  env: Env,
  hash: string,
  externalId: string,
  record: ActivityRecord,
): Promise<void> {
  const d1 = db(env);
  if (!d1) {
    await env.ZW_KV.put(keys.activity(hash, externalId), json(record));
    return;
  }
  await d1
    .prepare(
      `INSERT OR REPLACE INTO activities (tenant_id, api_key_hash, external_id, json, updated_at)
       VALUES (?, ?, ?, ?, ?)`,
    )
    .bind(tenantId(hash), hash, externalId, json(record), record.updatedAt)
    .run();
}

export async function getActivity(
  env: Env,
  hash: string,
  externalId: string,
): Promise<ActivityRecord | null> {
  const d1 = db(env);
  if (!d1) {
    const raw = await env.ZW_KV.get(keys.activity(hash, externalId));
    return raw ? parseJson<ActivityRecord>(raw) : null;
  }

  const row = await d1
    .prepare(`SELECT json FROM activities WHERE tenant_id = ? AND external_id = ?`)
    .bind(tenantId(hash), externalId)
    .first<JsonRow>();
  if (row) return parseJson<ActivityRecord>(row.json);

  if (!legacyFallbackEnabled(env)) return null;
  const legacy = await env.ZW_KV.get(keys.activity(hash, externalId));
  if (!legacy) return null;
  const record = parseJson<ActivityRecord>(legacy);
  await putActivity(env, hash, externalId, record);
  return record;
}

export async function deleteActivity(env: Env, hash: string, externalId: string): Promise<void> {
  const d1 = db(env);
  if (d1) {
    await d1
      .prepare(`DELETE FROM activities WHERE tenant_id = ? AND external_id = ?`)
      .bind(tenantId(hash), externalId)
      .run();
  }
  if (!d1 || legacyFallbackEnabled(env)) {
    await env.ZW_KV.delete(keys.activity(hash, externalId));
  }
}

export async function putPendingActivity(
  env: Env,
  hash: string,
  externalId: string,
  record: PendingActivityRecord,
): Promise<void> {
  const d1 = db(env);
  if (!d1) {
    await env.ZW_KV.put(keys.pendingActivity(hash, externalId), json(record));
    return;
  }
  await d1
    .prepare(
      `INSERT OR REPLACE INTO pending_activities
       (tenant_id, api_key_hash, external_id, json, updated_at)
       VALUES (?, ?, ?, ?, ?)`,
    )
    .bind(tenantId(hash), hash, externalId, json(record), record.updatedAt)
    .run();
}

export async function getPendingActivity(
  env: Env,
  hash: string,
  externalId: string,
): Promise<PendingActivityRecord | null> {
  const d1 = db(env);
  if (!d1) {
    const raw = await env.ZW_KV.get(keys.pendingActivity(hash, externalId));
    return raw ? parseJson<PendingActivityRecord>(raw) : null;
  }

  const row = await d1
    .prepare(`SELECT json FROM pending_activities WHERE tenant_id = ? AND external_id = ?`)
    .bind(tenantId(hash), externalId)
    .first<JsonRow>();
  if (row) return parseJson<PendingActivityRecord>(row.json);

  if (!legacyFallbackEnabled(env)) return null;
  const legacy = await env.ZW_KV.get(keys.pendingActivity(hash, externalId));
  if (!legacy) return null;
  const record = parseJson<PendingActivityRecord>(legacy);
  await putPendingActivity(env, hash, externalId, record);
  return record;
}

export async function deletePendingActivity(
  env: Env,
  hash: string,
  externalId: string,
): Promise<void> {
  const d1 = db(env);
  if (d1) {
    await d1
      .prepare(`DELETE FROM pending_activities WHERE tenant_id = ? AND external_id = ?`)
      .bind(tenantId(hash), externalId)
      .run();
  }
  if (!d1 || legacyFallbackEnabled(env)) {
    await env.ZW_KV.delete(keys.pendingActivity(hash, externalId));
  }
}

export async function putStartToken(
  env: Env,
  hash: string,
  deviceId: string,
  attributesType: string,
  pushToken: string,
): Promise<void> {
  const d1 = db(env);
  if (!d1) {
    await env.ZW_KV.put(keys.startToken(hash, deviceId, attributesType), pushToken);
    return;
  }
  await d1
    .prepare(
      `INSERT OR REPLACE INTO start_tokens
       (tenant_id, api_key_hash, device_id, attributes_type, token, updated_at)
       VALUES (?, ?, ?, ?, ?, ?)`,
    )
    .bind(tenantId(hash), hash, deviceId, attributesType, pushToken, nowIso())
    .run();
}

export async function listStartTokens(
  env: Env,
  hash: string,
  attributesType: string,
): Promise<string[]> {
  const d1 = db(env);
  if (!d1) return legacyListStartTokens(env, hash, attributesType);

  const rows = await d1
    .prepare(
      `SELECT token FROM start_tokens
       WHERE tenant_id = ? AND attributes_type = ?
       ORDER BY device_id`,
    )
    .bind(tenantId(hash), attributesType)
    .all<TokenRow>();
  if (rows.results.length > 0) return rows.results.map((row) => row.token);
  if (!legacyFallbackEnabled(env)) return [];

  const prefix = `start-token:${hash}:`;
  const legacy = await listKv(env, prefix, (key, token) => {
    const suffix = parseScopedSuffix(key, prefix);
    const parts = suffix ? splitLast(suffix) : null;
    if (!parts || parts[1] !== attributesType) return null;
    return { deviceId: parts[0], token };
  });
  for (const row of legacy) {
    await putStartToken(env, hash, row.deviceId, attributesType, row.token);
  }
  return legacy.map((row) => row.token);
}

// ---------- Cross-API-key listing (admin dashboard) ----------

export interface ScopedEntry<T> {
  apiKeyHash: string;
  key: string;
  value: T;
}

async function listAllKv<T>(
  env: Env,
  prefix: string,
  parse: (raw: string) => T,
): Promise<ScopedEntry<T>[]> {
  return listKv(env, prefix, (key, raw) => ({
    apiKeyHash: key.split(":")[1] ?? "",
    key,
    value: parse(raw),
  }));
}

export async function listAllCards(env: Env): Promise<ScopedEntry<DashboardCard>[]> {
  const d1 = db(env);
  if (!d1) return listAllKv(env, "card:", (raw) => parseJson<DashboardCard>(raw));
  const rows = await d1
    .prepare(`SELECT api_key_hash, id, json FROM cards ORDER BY api_key_hash, id`)
    .all<{ api_key_hash: string; id: string; json: string }>();
  if (rows.results.length === 0 && legacyFallbackEnabled(env)) {
    return listAllKv(env, "card:", (raw) => parseJson<DashboardCard>(raw));
  }
  return rows.results.map((row) => ({
    apiKeyHash: row.api_key_hash,
    key: keys.card(row.api_key_hash, row.id),
    value: parseJson<DashboardCard>(row.json),
  }));
}

export async function listAllDevices(env: Env): Promise<ScopedEntry<DeviceRecord>[]> {
  const d1 = db(env);
  if (!d1) return listAllKv(env, "device:", (raw) => parseJson<DeviceRecord>(raw));
  const rows = await d1
    .prepare(`SELECT api_key_hash, device_id, json FROM devices ORDER BY api_key_hash, device_id`)
    .all<{ api_key_hash: string; device_id: string; json: string }>();
  if (rows.results.length === 0 && legacyFallbackEnabled(env)) {
    return listAllKv(env, "device:", (raw) => parseJson<DeviceRecord>(raw));
  }
  return rows.results.map((row) => ({
    apiKeyHash: row.api_key_hash,
    key: keys.device(row.api_key_hash, row.device_id),
    value: parseJson<DeviceRecord>(row.json),
  }));
}

export async function listAllWidgetTokens(env: Env): Promise<ScopedEntry<string>[]> {
  const d1 = db(env);
  if (!d1) return listAllKv(env, "widget-token:", (raw) => raw);
  const rows = await d1
    .prepare(
      `SELECT api_key_hash, device_id, widget_kind, token
       FROM widget_tokens
       ORDER BY api_key_hash, device_id, widget_kind`,
    )
    .all<{ api_key_hash: string; device_id: string; widget_kind: string; token: string }>();
  if (rows.results.length === 0 && legacyFallbackEnabled(env)) {
    return listAllKv(env, "widget-token:", (raw) => raw);
  }
  return rows.results.map((row) => ({
    apiKeyHash: row.api_key_hash,
    key: keys.widgetToken(row.api_key_hash, row.device_id, row.widget_kind),
    value: row.token,
  }));
}

export async function listAllActivities(env: Env): Promise<ScopedEntry<ActivityRecord>[]> {
  const d1 = db(env);
  if (!d1) return listAllKv(env, "activity:", (raw) => parseJson<ActivityRecord>(raw));
  const rows = await d1
    .prepare(
      `SELECT api_key_hash, external_id, json
       FROM activities
       ORDER BY api_key_hash, external_id`,
    )
    .all<{ api_key_hash: string; external_id: string; json: string }>();
  if (rows.results.length === 0 && legacyFallbackEnabled(env)) {
    return listAllKv(env, "activity:", (raw) => parseJson<ActivityRecord>(raw));
  }
  return rows.results.map((row) => ({
    apiKeyHash: row.api_key_hash,
    key: keys.activity(row.api_key_hash, row.external_id),
    value: parseJson<ActivityRecord>(row.json),
  }));
}

export async function listAllPendingActivities(env: Env): Promise<ScopedEntry<unknown>[]> {
  const d1 = db(env);
  if (!d1) return listAllKv(env, "pending-activity:", (raw) => parseJson<unknown>(raw));
  const rows = await d1
    .prepare(
      `SELECT api_key_hash, external_id, json
       FROM pending_activities
       ORDER BY api_key_hash, external_id`,
    )
    .all<{ api_key_hash: string; external_id: string; json: string }>();
  if (rows.results.length === 0 && legacyFallbackEnabled(env)) {
    return listAllKv(env, "pending-activity:", (raw) => parseJson<unknown>(raw));
  }
  return rows.results.map((row) => ({
    apiKeyHash: row.api_key_hash,
    key: keys.pendingActivity(row.api_key_hash, row.external_id),
    value: parseJson<PendingActivityRecord>(row.json),
  }));
}

export async function listAllStartTokens(env: Env): Promise<ScopedEntry<string>[]> {
  const d1 = db(env);
  if (!d1) return listAllKv(env, "start-token:", (raw) => raw);
  const rows = await d1
    .prepare(
      `SELECT api_key_hash, device_id, attributes_type, token
       FROM start_tokens
       ORDER BY api_key_hash, device_id, attributes_type`,
    )
    .all<{ api_key_hash: string; device_id: string; attributes_type: string; token: string }>();
  if (rows.results.length === 0 && legacyFallbackEnabled(env)) {
    return listAllKv(env, "start-token:", (raw) => raw);
  }
  return rows.results.map((row) => ({
    apiKeyHash: row.api_key_hash,
    key: keys.startToken(row.api_key_hash, row.device_id, row.attributes_type),
    value: row.token,
  }));
}

// ---------- Per-API-key (existing) ----------

export async function listPendingActivities(
  env: Env,
  hash: string,
): Promise<PendingActivityRecord[]> {
  const d1 = db(env);
  if (!d1) return legacyListPendingActivities(env, hash);

  const rows = await d1
    .prepare(`SELECT json FROM pending_activities WHERE tenant_id = ? ORDER BY external_id`)
    .bind(tenantId(hash))
    .all<JsonRow>();
  if (rows.results.length > 0) {
    return rows.results.map((row) => parseJson<PendingActivityRecord>(row.json));
  }
  if (!legacyFallbackEnabled(env)) return [];

  const legacy = await legacyListPendingActivities(env, hash);
  for (const record of legacy) {
    await putPendingActivity(env, hash, record.externalActivityId, record);
  }
  return legacy;
}
