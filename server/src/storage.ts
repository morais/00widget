import type { Env, DashboardCard, StartLiveActivity } from "./types";

export const keys = {
  card: (hash: string, id: string) => `card:${hash}:${id}`,
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

function tenantId(apiKeyHash: string): string {
  return apiKeyHash;
}

async function upsertCardD1(env: Env, hash: string, card: DashboardCard): Promise<void> {
  await env.ZW_DB.prepare(
    `INSERT OR REPLACE INTO cards (tenant_id, api_key_hash, id, json, updated_at)
     VALUES (?, ?, ?, ?, ?)`,
  )
    .bind(tenantId(hash), hash, card.id, json(card), card.updatedAt ?? nowIso())
    .run();
}

export async function putCard(env: Env, hash: string, card: DashboardCard): Promise<void> {
  await upsertCardD1(env, hash, card);
}

export async function getCard(env: Env, hash: string, id: string): Promise<DashboardCard | null> {
  const row = await env.ZW_DB.prepare(`SELECT json FROM cards WHERE tenant_id = ? AND id = ?`)
    .bind(tenantId(hash), id)
    .first<JsonRow>();
  return row ? parseJson<DashboardCard>(row.json) : null;
}

export async function listCards(env: Env, hash: string): Promise<DashboardCard[]> {
  const rows = await env.ZW_DB.prepare(`SELECT json FROM cards WHERE tenant_id = ? ORDER BY id`)
    .bind(tenantId(hash))
    .all<JsonRow>();
  return rows.results.map((row) => parseJson<DashboardCard>(row.json));
}

export async function deleteCard(env: Env, hash: string, id: string): Promise<void> {
  await env.ZW_DB.prepare(`DELETE FROM cards WHERE tenant_id = ? AND id = ?`)
    .bind(tenantId(hash), id)
    .run();
}

export async function putDevice(
  env: Env,
  hash: string,
  deviceId: string,
  record: DeviceRecord,
): Promise<void> {
  await env.ZW_DB.prepare(
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
  await env.ZW_DB.prepare(
    `INSERT OR REPLACE INTO widget_tokens
     (tenant_id, api_key_hash, device_id, widget_kind, token, updated_at)
     VALUES (?, ?, ?, ?, ?, ?)`,
  )
    .bind(tenantId(hash), hash, deviceId, widgetKind, token, nowIso())
    .run();
}

export async function listWidgetTokens(env: Env, hash: string): Promise<string[]> {
  const rows = await env.ZW_DB.prepare(
    `SELECT token FROM widget_tokens
     WHERE tenant_id = ?
     ORDER BY device_id, widget_kind`,
  )
    .bind(tenantId(hash))
    .all<TokenRow>();
  return rows.results.map((row) => row.token);
}

export async function listWidgetTokensForKind(
  env: Env,
  hash: string,
  widgetKind: string,
): Promise<string[]> {
  const rows = await env.ZW_DB.prepare(
    `SELECT token FROM widget_tokens
     WHERE tenant_id = ? AND widget_kind = ?
     ORDER BY device_id`,
  )
    .bind(tenantId(hash), widgetKind)
    .all<TokenRow>();
  return rows.results.map((row) => row.token);
}

export async function putActivity(
  env: Env,
  hash: string,
  externalId: string,
  record: ActivityRecord,
): Promise<void> {
  await env.ZW_DB.prepare(
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
  const row = await env.ZW_DB.prepare(
    `SELECT json FROM activities WHERE tenant_id = ? AND external_id = ?`,
  )
    .bind(tenantId(hash), externalId)
    .first<JsonRow>();
  return row ? parseJson<ActivityRecord>(row.json) : null;
}

export async function deleteActivity(env: Env, hash: string, externalId: string): Promise<void> {
  await env.ZW_DB.prepare(`DELETE FROM activities WHERE tenant_id = ? AND external_id = ?`)
    .bind(tenantId(hash), externalId)
    .run();
}

export async function putPendingActivity(
  env: Env,
  hash: string,
  externalId: string,
  record: PendingActivityRecord,
): Promise<void> {
  await env.ZW_DB.prepare(
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
  const row = await env.ZW_DB.prepare(
    `SELECT json FROM pending_activities WHERE tenant_id = ? AND external_id = ?`,
  )
    .bind(tenantId(hash), externalId)
    .first<JsonRow>();
  return row ? parseJson<PendingActivityRecord>(row.json) : null;
}

export async function deletePendingActivity(
  env: Env,
  hash: string,
  externalId: string,
): Promise<void> {
  await env.ZW_DB.prepare(`DELETE FROM pending_activities WHERE tenant_id = ? AND external_id = ?`)
    .bind(tenantId(hash), externalId)
    .run();
}

export async function putStartToken(
  env: Env,
  hash: string,
  deviceId: string,
  attributesType: string,
  pushToken: string,
): Promise<void> {
  await env.ZW_DB.prepare(
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
  const rows = await env.ZW_DB.prepare(
    `SELECT token FROM start_tokens
     WHERE tenant_id = ? AND attributes_type = ?
     ORDER BY device_id`,
  )
    .bind(tenantId(hash), attributesType)
    .all<TokenRow>();
  return rows.results.map((row) => row.token);
}

// ---------- Cross-API-key listing (admin dashboard) ----------

export interface ScopedEntry<T> {
  apiKeyHash: string;
  key: string;
  value: T;
}

export async function listAllCards(env: Env): Promise<ScopedEntry<DashboardCard>[]> {
  const rows = await env.ZW_DB.prepare(
    `SELECT api_key_hash, id, json FROM cards ORDER BY api_key_hash, id`,
  ).all<{ api_key_hash: string; id: string; json: string }>();
  return rows.results.map((row) => ({
    apiKeyHash: row.api_key_hash,
    key: keys.card(row.api_key_hash, row.id),
    value: parseJson<DashboardCard>(row.json),
  }));
}

export async function listAllDevices(env: Env): Promise<ScopedEntry<DeviceRecord>[]> {
  const rows = await env.ZW_DB.prepare(
    `SELECT api_key_hash, device_id, json FROM devices ORDER BY api_key_hash, device_id`,
  ).all<{ api_key_hash: string; device_id: string; json: string }>();
  return rows.results.map((row) => ({
    apiKeyHash: row.api_key_hash,
    key: keys.device(row.api_key_hash, row.device_id),
    value: parseJson<DeviceRecord>(row.json),
  }));
}

export async function listAllWidgetTokens(env: Env): Promise<ScopedEntry<string>[]> {
  const rows = await env.ZW_DB.prepare(
    `SELECT api_key_hash, device_id, widget_kind, token
     FROM widget_tokens
     ORDER BY api_key_hash, device_id, widget_kind`,
  ).all<{ api_key_hash: string; device_id: string; widget_kind: string; token: string }>();
  return rows.results.map((row) => ({
    apiKeyHash: row.api_key_hash,
    key: keys.widgetToken(row.api_key_hash, row.device_id, row.widget_kind),
    value: row.token,
  }));
}

export async function listAllActivities(env: Env): Promise<ScopedEntry<ActivityRecord>[]> {
  const rows = await env.ZW_DB.prepare(
    `SELECT api_key_hash, external_id, json
     FROM activities
     ORDER BY api_key_hash, external_id`,
  ).all<{ api_key_hash: string; external_id: string; json: string }>();
  return rows.results.map((row) => ({
    apiKeyHash: row.api_key_hash,
    key: keys.activity(row.api_key_hash, row.external_id),
    value: parseJson<ActivityRecord>(row.json),
  }));
}

export async function listAllPendingActivities(env: Env): Promise<ScopedEntry<unknown>[]> {
  const rows = await env.ZW_DB.prepare(
    `SELECT api_key_hash, external_id, json
     FROM pending_activities
     ORDER BY api_key_hash, external_id`,
  ).all<{ api_key_hash: string; external_id: string; json: string }>();
  return rows.results.map((row) => ({
    apiKeyHash: row.api_key_hash,
    key: keys.pendingActivity(row.api_key_hash, row.external_id),
    value: parseJson<PendingActivityRecord>(row.json),
  }));
}

export async function listAllStartTokens(env: Env): Promise<ScopedEntry<string>[]> {
  const rows = await env.ZW_DB.prepare(
    `SELECT api_key_hash, device_id, attributes_type, token
     FROM start_tokens
     ORDER BY api_key_hash, device_id, attributes_type`,
  ).all<{ api_key_hash: string; device_id: string; attributes_type: string; token: string }>();
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
  const rows = await env.ZW_DB.prepare(
    `SELECT json FROM pending_activities WHERE tenant_id = ? ORDER BY external_id`,
  )
    .bind(tenantId(hash))
    .all<JsonRow>();
  return rows.results.map((row) => parseJson<PendingActivityRecord>(row.json));
}
