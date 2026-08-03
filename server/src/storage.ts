import type {
  ActionPayload,
  DashboardCard,
  DashboardCardInput,
  Env,
  LiveActivitySession,
} from "./types";
import { DashboardCardSchema } from "./types";

export const keys = {
  card: (hash: string, id: string) => `card:${hash}:${id}`,
  device: (hash: string, deviceId: string) => `device:${hash}:${deviceId}`,
  widgetToken: (hash: string, deviceId: string, kind: string) =>
    `widget-token:${hash}:${deviceId}:${kind}`,
  activity: (hash: string, instanceId: string) => `activity:${hash}:${instanceId}`,
  pendingActivity: (hash: string, instanceId: string) =>
    `pending-activity:${hash}:${instanceId}`,
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
  title?: string;
  icon?: string;
  deepLink?: string;
  startedAt?: string;
  relevanceScore?: number;
  updatedAt: string;
  lastState?: unknown;
}

export interface ActivityDelivery {
  activityInstanceId: string;
  ownerTenantId: string;
  targetTenantId: string;
  shareId?: string;
  apiKeyHash: string;
  record: ActivityRecord;
}

export interface ActivityTarget {
  activityInstanceId: string;
  ownerTenantId: string;
  targetTenantId: string;
  shareId?: string;
}

export interface WebhookIntegrationRecord {
  url: string;
  signingSecret: string;
  createdAt: string;
  updatedAt: string;
}

interface JsonRow {
  json: string;
}

interface TokenRow {
  token: string;
}

interface WidgetTokenRow extends TokenRow {
  card_ids_json: string;
  all_cards: number;
}

export interface WidgetPushSubscription {
  widgetKind: string;
  cardIds: string[];
  allCards: boolean;
}

export interface WidgetTokenMetadata {
  appVersion: string;
  platform: string;
}

export interface WidgetTokenRecord extends WidgetTokenMetadata {
  token: string;
  updatedAt: string;
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

function parsePublicCard(raw: string): DashboardCard {
  return DashboardCardSchema.parse(JSON.parse(raw));
}

function publicCard(card: DashboardCardInput): DashboardCard {
  return {
    ...card,
    actions: card.actions?.map(({ payload: _payload, ...action }) => action),
  };
}

function cardWriteStatements(
  env: Env,
  tenantId: string,
  apiKeyHash: string,
  card: DashboardCardInput,
): { card: DashboardCard; statements: D1PreparedStatement[] } {
  const sanitized = publicCard(card);
  const updatedAt = sanitized.updatedAt ?? nowIso();
  const statements: D1PreparedStatement[] = [
    env.ZW_DB.prepare(
      `DELETE FROM action_payloads WHERE tenant_id = ? AND card_id = ?`,
    ).bind(tenantId, sanitized.id),
  ];
  for (const action of card.actions ?? []) {
    if (action.payload === undefined) continue;
    statements.push(
      env.ZW_DB.prepare(
        `INSERT OR REPLACE INTO action_payloads
           (tenant_id, api_key_hash, card_id, action_id, json, updated_at)
         VALUES (?, ?, ?, ?, ?, ?)`,
      ).bind(
        tenantId,
        apiKeyHash,
        sanitized.id,
        action.id,
        json(action.payload),
        updatedAt,
      ),
    );
  }
  statements.push(
    env.ZW_DB.prepare(
      `INSERT OR REPLACE INTO cards (tenant_id, api_key_hash, id, json, updated_at)
       VALUES (?, ?, ?, ?, ?)`,
    ).bind(tenantId, apiKeyHash, sanitized.id, json(sanitized), updatedAt),
  );
  return { card: sanitized, statements };
}

export async function putCard(
  env: Env,
  tenantId: string,
  apiKeyHash: string,
  card: DashboardCardInput,
): Promise<DashboardCard> {
  const prepared = cardWriteStatements(env, tenantId, apiKeyHash, card);
  await env.ZW_DB.batch(prepared.statements);
  return prepared.card;
}

export async function putCards(
  env: Env,
  tenantId: string,
  apiKeyHash: string,
  cards: DashboardCardInput[],
): Promise<DashboardCard[]> {
  if (cards.length === 0) return [];
  const prepared = cards.map((card) => cardWriteStatements(env, tenantId, apiKeyHash, card));
  await env.ZW_DB.batch(prepared.flatMap((item) => item.statements));
  return prepared.map((item) => item.card);
}

export async function getCard(env: Env, tenantId: string, id: string): Promise<DashboardCard | null> {
  const row = await env.ZW_DB.prepare(`SELECT json FROM cards WHERE tenant_id = ? AND id = ?`)
    .bind(tenantId, id)
    .first<JsonRow>();
  return row ? parsePublicCard(row.json) : null;
}

export async function listCards(env: Env, tenantId: string): Promise<DashboardCard[]> {
  const rows = await env.ZW_DB.prepare(`SELECT json FROM cards WHERE tenant_id = ? ORDER BY id`)
    .bind(tenantId)
    .all<JsonRow>();
  return rows.results.map((row) => parsePublicCard(row.json));
}

export async function getActionPayload(
  env: Env,
  tenantId: string,
  cardId: string,
  actionId: string,
): Promise<ActionPayload | null> {
  const row = await env.ZW_DB.prepare(
    `SELECT json FROM action_payloads
     WHERE tenant_id = ? AND card_id = ? AND action_id = ?`,
  )
    .bind(tenantId, cardId, actionId)
    .first<JsonRow>();
  return row ? parseJson<ActionPayload>(row.json) : null;
}

export async function deleteCard(env: Env, tenantId: string, id: string): Promise<void> {
  await env.ZW_DB.batch([
    env.ZW_DB.prepare(
      `DELETE FROM action_payloads WHERE tenant_id = ? AND card_id = ?`,
    ).bind(tenantId, id),
    env.ZW_DB.prepare(`DELETE FROM cards WHERE tenant_id = ? AND id = ?`).bind(tenantId, id),
  ]);
}

export async function getWebhookIntegration(
  env: Env,
  tenantId: string,
): Promise<WebhookIntegrationRecord | null> {
  const row = await env.ZW_DB.prepare(
    `SELECT json FROM webhook_integrations WHERE tenant_id = ?`,
  )
    .bind(tenantId)
    .first<JsonRow>();
  return row ? parseJson<WebhookIntegrationRecord>(row.json) : null;
}

export async function putWebhookIntegration(
  env: Env,
  tenantId: string,
  apiKeyHash: string,
  record: WebhookIntegrationRecord,
): Promise<void> {
  await env.ZW_DB.prepare(
    `INSERT OR REPLACE INTO webhook_integrations
     (tenant_id, api_key_hash, json, updated_at)
     VALUES (?, ?, ?, ?)`,
  )
    .bind(tenantId, apiKeyHash, json(record), record.updatedAt)
    .run();
}

export async function deleteWebhookIntegration(env: Env, tenantId: string): Promise<void> {
  await env.ZW_DB.prepare(`DELETE FROM webhook_integrations WHERE tenant_id = ?`)
    .bind(tenantId)
    .run();
}

export async function putDevice(
  env: Env,
  tenantId: string,
  apiKeyHash: string,
  deviceId: string,
  record: DeviceRecord,
): Promise<void> {
  await env.ZW_DB.prepare(
    `INSERT OR REPLACE INTO devices (tenant_id, api_key_hash, device_id, json, updated_at)
     VALUES (?, ?, ?, ?, ?)`,
  )
    .bind(tenantId, apiKeyHash, deviceId, json(record), record.updatedAt)
    .run();
}

export async function putWidgetToken(
  env: Env,
  tenantId: string,
  apiKeyHash: string,
  deviceId: string,
  widgetKind: string,
  token: string,
  subscription: Pick<WidgetPushSubscription, "cardIds" | "allCards"> = {
    cardIds: [],
    allCards: true,
  },
  metadata: WidgetTokenMetadata = { appVersion: "0.0", platform: "ios" },
): Promise<void> {
  await env.ZW_DB.prepare(
    `INSERT OR REPLACE INTO widget_tokens
     (tenant_id, api_key_hash, device_id, widget_kind, token, updated_at,
      card_ids_json, all_cards, app_version, platform)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  )
    .bind(
      tenantId,
      apiKeyHash,
      deviceId,
      widgetKind,
      token,
      nowIso(),
      json([...new Set(subscription.cardIds)]),
      subscription.allCards ? 1 : 0,
      metadata.appVersion,
      metadata.platform,
    )
    .run();
}

export async function replaceWidgetTokensForDevice(
  env: Env,
  tenantId: string,
  apiKeyHash: string,
  deviceId: string,
  token: string | undefined,
  subscriptions: WidgetPushSubscription[],
  metadata: WidgetTokenMetadata = { appVersion: "0.0", platform: "ios" },
): Promise<void> {
  const statements: D1PreparedStatement[] = [
    env.ZW_DB.prepare(
      `DELETE FROM widget_tokens WHERE tenant_id = ? AND device_id = ?`,
    ).bind(tenantId, deviceId),
  ];
  if (token) {
    // WidgetKit tokens are device-specific. If an app reinstall creates a new
    // device id while WidgetKit reissues the same token, move that token to the
    // current device instead of leaving an orphan that can later fan out twice.
    statements.push(
      env.ZW_DB.prepare(
        `DELETE FROM widget_tokens
         WHERE tenant_id = ? AND token = ? AND device_id <> ?`,
      ).bind(tenantId, token, deviceId),
    );
    const merged = new Map<string, WidgetPushSubscription>();
    for (const subscription of subscriptions) {
      const existing = merged.get(subscription.widgetKind);
      merged.set(subscription.widgetKind, {
        widgetKind: subscription.widgetKind,
        cardIds: [...new Set([...(existing?.cardIds ?? []), ...subscription.cardIds])],
        allCards: Boolean(existing?.allCards || subscription.allCards),
      });
    }
    for (const subscription of merged.values()) {
      if (!subscription.allCards && subscription.cardIds.length === 0) continue;
      statements.push(
        env.ZW_DB.prepare(
          `INSERT OR REPLACE INTO widget_tokens
           (tenant_id, api_key_hash, device_id, widget_kind, token, updated_at,
            card_ids_json, all_cards, app_version, platform)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        ).bind(
          tenantId,
          apiKeyHash,
          deviceId,
          subscription.widgetKind,
          token,
          nowIso(),
          json(subscription.cardIds),
          subscription.allCards ? 1 : 0,
          metadata.appVersion,
          metadata.platform,
        ),
      );
    }
  }
  await env.ZW_DB.batch(statements);
}

export async function deleteWidgetToken(
  env: Env,
  tenantId: string,
  deviceId: string,
  widgetKind: string,
): Promise<void> {
  await env.ZW_DB.prepare(
    `DELETE FROM widget_tokens
     WHERE tenant_id = ? AND device_id = ? AND widget_kind = ?`,
  )
    .bind(tenantId, deviceId, widgetKind)
    .run();
}

export async function deleteWidgetTokenByValue(
  env: Env,
  tenantId: string,
  token: string,
): Promise<void> {
  await env.ZW_DB.prepare(
    `DELETE FROM widget_tokens WHERE tenant_id = ? AND token = ?`,
  )
    .bind(tenantId, token)
    .run();
}

export async function listWidgetTokens(env: Env, tenantId: string): Promise<string[]> {
  const rows = await env.ZW_DB.prepare(
    `SELECT token FROM widget_tokens
     WHERE tenant_id = ?
     ORDER BY device_id, widget_kind`,
  )
    .bind(tenantId)
    .all<TokenRow>();
  return rows.results.map((row) => row.token);
}

export async function listWidgetTokensForKind(
  env: Env,
  tenantId: string,
  widgetKind: string,
): Promise<string[]> {
  const rows = await env.ZW_DB.prepare(
    `SELECT token FROM widget_tokens
     WHERE tenant_id = ? AND widget_kind = ?
     ORDER BY device_id`,
  )
    .bind(tenantId, widgetKind)
    .all<TokenRow>();
  return rows.results.map((row) => row.token);
}

export async function listWidgetTokensForCard(
  env: Env,
  tenantId: string,
  cardId: string,
): Promise<string[]> {
  const rows = await env.ZW_DB.prepare(
    `SELECT token, card_ids_json, all_cards FROM widget_tokens
     WHERE tenant_id = ?
     ORDER BY device_id, widget_kind`,
  )
    .bind(tenantId)
    .all<WidgetTokenRow>();
  return [
    ...new Set(
      rows.results
        .filter((row) => {
          if (Number(row.all_cards) === 1) return true;
          try {
            const cardIds = parseJson<unknown>(row.card_ids_json);
            return Array.isArray(cardIds) && cardIds.includes(cardId);
          } catch {
            return true;
          }
        })
        .map((row) => row.token),
    ),
  ];
}

export async function putActivityInstance(
  env: Env,
  ownerTenantId: string,
  apiKeyHash: string,
  session: LiveActivitySession,
): Promise<void> {
  await env.ZW_DB.prepare(
    `INSERT INTO activity_instances
     (id, owner_tenant_id, api_key_hash, external_id, kind, json, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(id) DO UPDATE SET
       api_key_hash = excluded.api_key_hash,
       kind = excluded.kind,
       json = excluded.json,
       updated_at = excluded.updated_at`,
  )
    .bind(
      session.activityInstanceId,
      ownerTenantId,
      apiKeyHash,
      session.externalActivityId,
      session.kind,
      json(session),
      session.updatedAt,
    )
    .run();
}

/// Looks up an instance by its server-issued id, but only if `targetTenantId`
/// is one of its delivery targets. The scope belongs in the query: a caller
/// that resolved the instance first and checked the target afterwards would
/// still be correct, but it leaves an unscoped read in this module for the
/// next person to reuse without the follow-up check.
export async function getActivityInstanceForTarget(
  env: Env,
  activityInstanceId: string,
  targetTenantId: string,
): Promise<LiveActivitySession | null> {
  const row = await env.ZW_DB.prepare(
    `SELECT instances.json AS json
     FROM activity_instances AS instances
     JOIN activity_targets AS targets ON targets.activity_instance_id = instances.id
     WHERE instances.id = ? AND targets.target_tenant_id = ?`,
  )
    .bind(activityInstanceId, targetTenantId)
    .first<JsonRow>();
  return row ? parseJson<LiveActivitySession>(row.json) : null;
}

export async function getActivityInstanceByOwnerExternal(
  env: Env,
  ownerTenantId: string,
  externalId: string,
): Promise<LiveActivitySession | null> {
  const row = await env.ZW_DB.prepare(
    `SELECT json FROM activity_instances
     WHERE owner_tenant_id = ? AND external_id = ?`,
  )
    .bind(ownerTenantId, externalId)
    .first<JsonRow>();
  return row ? parseJson<LiveActivitySession>(row.json) : null;
}

export async function listActivityInstancesForTarget(
  env: Env,
  targetTenantId: string,
): Promise<LiveActivitySession[]> {
  const rows = await env.ZW_DB.prepare(
    `SELECT instances.json AS json
     FROM activity_instances AS instances
     JOIN activity_targets AS targets ON targets.activity_instance_id = instances.id
     WHERE targets.target_tenant_id = ?
     ORDER BY instances.updated_at DESC, instances.id`,
  )
    .bind(targetTenantId)
    .all<JsonRow>();
  return rows.results.map((row) => parseJson<LiveActivitySession>(row.json));
}

export async function listActivityInstancesByOwnerKind(
  env: Env,
  ownerTenantId: string,
  kind: string,
): Promise<LiveActivitySession[]> {
  const rows = await env.ZW_DB.prepare(
    `SELECT json FROM activity_instances
     WHERE owner_tenant_id = ? AND kind = ?
     ORDER BY updated_at DESC, id`,
  )
    .bind(ownerTenantId, kind)
    .all<JsonRow>();
  return rows.results.map((row) => parseJson<LiveActivitySession>(row.json));
}

export async function putActivityTarget(
  env: Env,
  activityInstanceId: string,
  ownerTenantId: string,
  targetTenantId: string,
  shareId?: string,
): Promise<void> {
  await env.ZW_DB.prepare(
    `INSERT OR REPLACE INTO activity_targets
     (activity_instance_id, owner_tenant_id, target_tenant_id, share_id, created_at)
     VALUES (?, ?, ?, ?, ?)`,
  )
    .bind(activityInstanceId, ownerTenantId, targetTenantId, shareId ?? null, nowIso())
    .run();
}

export async function getActivityTarget(
  env: Env,
  activityInstanceId: string,
  targetTenantId: string,
): Promise<ActivityTarget | null> {
  const row = await env.ZW_DB.prepare(
    `SELECT activity_instance_id, owner_tenant_id, target_tenant_id, share_id
     FROM activity_targets
     WHERE activity_instance_id = ? AND target_tenant_id = ?`,
  )
    .bind(activityInstanceId, targetTenantId)
    .first<{
      activity_instance_id: string;
      owner_tenant_id: string;
      target_tenant_id: string;
      share_id: string | null;
    }>();
  return row ? {
    activityInstanceId: row.activity_instance_id,
    ownerTenantId: row.owner_tenant_id,
    targetTenantId: row.target_tenant_id,
    shareId: row.share_id || undefined,
  } : null;
}

export async function resolveActivityRegistrationTargets(
  env: Env,
  targetTenantId: string,
  externalId: string,
  kind: string,
): Promise<LiveActivitySession[]> {
  const rows = await env.ZW_DB.prepare(
    `SELECT instances.json AS json
     FROM activity_instances AS instances
     JOIN activity_targets AS targets ON targets.activity_instance_id = instances.id
     WHERE targets.target_tenant_id = ?
       AND instances.external_id = ?
       AND instances.kind = ?
     ORDER BY instances.id`,
  )
    .bind(targetTenantId, externalId, kind)
    .all<JsonRow>();
  return rows.results.map((row) => parseJson<LiveActivitySession>(row.json));
}

export async function putActivityDelivery(
  env: Env,
  delivery: ActivityDelivery,
): Promise<void> {
  await env.ZW_DB.prepare(
    `INSERT OR REPLACE INTO activity_deliveries
     (activity_instance_id, owner_tenant_id, target_tenant_id, share_id,
      api_key_hash, device_id, json, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
  )
    .bind(
      delivery.activityInstanceId,
      delivery.ownerTenantId,
      delivery.targetTenantId,
      delivery.shareId ?? null,
      delivery.apiKeyHash,
      delivery.record.deviceId,
      json(delivery.record),
      delivery.record.updatedAt,
    )
    .run();
}

export async function listActivityDeliveries(
  env: Env,
  activityInstanceId: string,
): Promise<ActivityDelivery[]> {
  const rows = await env.ZW_DB.prepare(
    `SELECT activity_instance_id, owner_tenant_id, target_tenant_id,
            share_id, api_key_hash, json
     FROM activity_deliveries
     WHERE activity_instance_id = ?
     ORDER BY target_tenant_id, device_id`,
  )
    .bind(activityInstanceId)
    .all<{
      activity_instance_id: string;
      owner_tenant_id: string;
      target_tenant_id: string;
      share_id: string | null;
      api_key_hash: string;
      json: string;
    }>();
  return rows.results.map((row) => ({
    activityInstanceId: row.activity_instance_id,
    ownerTenantId: row.owner_tenant_id,
    targetTenantId: row.target_tenant_id,
    shareId: row.share_id || undefined,
    apiKeyHash: row.api_key_hash,
    record: parseJson<ActivityRecord>(row.json),
  }));
}

export async function listActivityDeliveriesForShare(
  env: Env,
  shareId: string,
): Promise<ActivityDelivery[]> {
  const rows = await env.ZW_DB.prepare(
    `SELECT activity_instance_id, owner_tenant_id, target_tenant_id,
            share_id, api_key_hash, json
     FROM activity_deliveries
     WHERE share_id = ?
     ORDER BY activity_instance_id, device_id`,
  )
    .bind(shareId)
    .all<{
      activity_instance_id: string;
      owner_tenant_id: string;
      target_tenant_id: string;
      share_id: string;
      api_key_hash: string;
      json: string;
    }>();
  return rows.results.map((row) => ({
    activityInstanceId: row.activity_instance_id,
    ownerTenantId: row.owner_tenant_id,
    targetTenantId: row.target_tenant_id,
    shareId: row.share_id,
    apiKeyHash: row.api_key_hash,
    record: parseJson<ActivityRecord>(row.json),
  }));
}

export async function deleteActivityShareTarget(env: Env, shareId: string): Promise<void> {
  await env.ZW_DB.batch([
    env.ZW_DB.prepare(`DELETE FROM activity_deliveries WHERE share_id = ?`).bind(shareId),
    env.ZW_DB.prepare(`DELETE FROM activity_targets WHERE share_id = ?`).bind(shareId),
  ]);
}

export async function deleteActivityInstance(
  env: Env,
  activityInstanceId: string,
): Promise<void> {
  await env.ZW_DB.batch([
    env.ZW_DB.prepare(
      `DELETE FROM activity_deliveries WHERE activity_instance_id = ?`,
    ).bind(activityInstanceId),
    env.ZW_DB.prepare(
      `DELETE FROM activity_targets WHERE activity_instance_id = ?`,
    ).bind(activityInstanceId),
    env.ZW_DB.prepare(`DELETE FROM activity_instances WHERE id = ?`).bind(activityInstanceId),
  ]);
}

export async function putStartToken(
  env: Env,
  tenantId: string,
  apiKeyHash: string,
  deviceId: string,
  attributesType: string,
  pushToken: string,
): Promise<void> {
  await env.ZW_DB.prepare(
    `INSERT OR REPLACE INTO start_tokens
     (tenant_id, api_key_hash, device_id, attributes_type, token, updated_at)
     VALUES (?, ?, ?, ?, ?, ?)`,
  )
    .bind(tenantId, apiKeyHash, deviceId, attributesType, pushToken, nowIso())
    .run();
}

export async function deleteStartToken(
  env: Env,
  tenantId: string,
  deviceId: string,
  attributesType: string,
): Promise<void> {
  await env.ZW_DB.prepare(
    `DELETE FROM start_tokens
     WHERE tenant_id = ? AND device_id = ? AND attributes_type = ?`,
  )
    .bind(tenantId, deviceId, attributesType)
    .run();
}

// Drops every start_tokens row whose `token` matches, scoped to a tenant and
// attributes type. Called when APNs reports the token as dead (BadDeviceToken,
// Unregistered, DeviceTokenNotForTopic) so subsequent /start calls don't keep
// fanning out to phantom devices.
export async function deleteStartTokenByValue(
  env: Env,
  tenantId: string,
  attributesType: string,
  token: string,
): Promise<void> {
  await env.ZW_DB.prepare(
    `DELETE FROM start_tokens
     WHERE tenant_id = ? AND attributes_type = ? AND token = ?`,
  )
    .bind(tenantId, attributesType, token)
    .run();
}

export async function listStartTokens(
  env: Env,
  tenantId: string,
  attributesType: string,
): Promise<string[]> {
  const rows = await env.ZW_DB.prepare(
    `SELECT token FROM start_tokens
     WHERE tenant_id = ? AND attributes_type = ?
     ORDER BY device_id`,
  )
    .bind(tenantId, attributesType)
    .all<TokenRow>();
  return rows.results.map((row) => row.token);
}

// ---------- Cross-API-key listing (admin dashboard) ----------

export interface ScopedEntry<T> {
  apiKeyHash: string;
  key: string;
  value: T;
}

export async function listTenantCards(
  env: Env,
  tenantId: string,
): Promise<ScopedEntry<DashboardCard>[]> {
  const rows = await env.ZW_DB.prepare(
    `SELECT api_key_hash, id, json
     FROM cards
     WHERE tenant_id = ?
     ORDER BY api_key_hash, id`,
  )
    .bind(tenantId)
    .all<{ api_key_hash: string; id: string; json: string }>();
  return rows.results.map((row) => ({
    apiKeyHash: row.api_key_hash,
    key: keys.card(row.api_key_hash, row.id),
    value: parsePublicCard(row.json),
  }));
}

export async function listTenantDevices(
  env: Env,
  tenantId: string,
): Promise<ScopedEntry<DeviceRecord>[]> {
  const rows = await env.ZW_DB.prepare(
    `SELECT api_key_hash, device_id, json
     FROM devices
     WHERE tenant_id = ?
     ORDER BY api_key_hash, device_id`,
  )
    .bind(tenantId)
    .all<{ api_key_hash: string; device_id: string; json: string }>();
  return rows.results.map((row) => ({
    apiKeyHash: row.api_key_hash,
    key: keys.device(row.api_key_hash, row.device_id),
    value: parseJson<DeviceRecord>(row.json),
  }));
}

export async function listTenantWidgetTokens(
  env: Env,
  tenantId: string,
): Promise<ScopedEntry<WidgetTokenRecord>[]> {
  const rows = await env.ZW_DB.prepare(
    `SELECT api_key_hash, device_id, widget_kind, token, updated_at, app_version, platform
     FROM widget_tokens
     WHERE tenant_id = ?
     ORDER BY api_key_hash, device_id, widget_kind`,
  )
    .bind(tenantId)
    .all<{
      api_key_hash: string;
      device_id: string;
      widget_kind: string;
      token: string;
      updated_at: string;
      app_version: string;
      platform: string;
    }>();
  return rows.results.map((row) => ({
    apiKeyHash: row.api_key_hash,
    key: keys.widgetToken(row.api_key_hash, row.device_id, row.widget_kind),
    value: {
      token: row.token,
      updatedAt: row.updated_at,
      appVersion: row.app_version,
      platform: row.platform,
    },
  }));
}

export async function listTenantActivities(
  env: Env,
  tenantId: string,
): Promise<ScopedEntry<ActivityRecord & { activityInstanceId: string; externalActivityId: string }>[]> {
  const rows = await env.ZW_DB.prepare(
    `SELECT deliveries.api_key_hash AS api_key_hash,
            deliveries.activity_instance_id AS activity_instance_id,
            instances.external_id AS external_id,
            deliveries.json AS json
     FROM activity_deliveries AS deliveries
     JOIN activity_instances AS instances ON instances.id = deliveries.activity_instance_id
     WHERE deliveries.target_tenant_id = ?
     ORDER BY deliveries.api_key_hash, instances.external_id, deliveries.device_id`,
  )
    .bind(tenantId)
    .all<{ api_key_hash: string; activity_instance_id: string; external_id: string; json: string }>();
  return rows.results.map((row) => ({
    apiKeyHash: row.api_key_hash,
    key: keys.activity(row.api_key_hash, row.activity_instance_id),
    value: {
      ...parseJson<ActivityRecord>(row.json),
      activityInstanceId: row.activity_instance_id,
      externalActivityId: row.external_id,
    },
  }));
}

export async function listTenantPendingActivities(
  env: Env,
  tenantId: string,
): Promise<ScopedEntry<LiveActivitySession>[]> {
  const rows = await env.ZW_DB.prepare(
    `SELECT instances.api_key_hash AS api_key_hash,
            instances.id AS activity_instance_id,
            instances.json AS json
     FROM activity_instances AS instances
     JOIN activity_targets AS targets ON targets.activity_instance_id = instances.id
     WHERE targets.target_tenant_id = ?
       AND NOT EXISTS (
         SELECT 1 FROM activity_deliveries AS deliveries
         WHERE deliveries.activity_instance_id = instances.id
           AND deliveries.target_tenant_id = targets.target_tenant_id
       )
     ORDER BY instances.api_key_hash, instances.external_id`,
  )
    .bind(tenantId)
    .all<{ api_key_hash: string; activity_instance_id: string; json: string }>();
  return rows.results.map((row) => ({
    apiKeyHash: row.api_key_hash,
    key: keys.pendingActivity(row.api_key_hash, row.activity_instance_id),
    value: parseJson<LiveActivitySession>(row.json),
  }));
}

export async function listTenantStartTokens(
  env: Env,
  tenantId: string,
): Promise<ScopedEntry<string>[]> {
  const rows = await env.ZW_DB.prepare(
    `SELECT api_key_hash, device_id, attributes_type, token
     FROM start_tokens
     WHERE tenant_id = ?
     ORDER BY api_key_hash, device_id, attributes_type`,
  )
    .bind(tenantId)
    .all<{ api_key_hash: string; device_id: string; attributes_type: string; token: string }>();
  return rows.results.map((row) => ({
    apiKeyHash: row.api_key_hash,
    key: keys.startToken(row.api_key_hash, row.device_id, row.attributes_type),
    value: row.token,
  }));
}

// ---------- Per-API-key (existing) ----------

export async function listPendingActivities(
  env: Env,
  tenantId: string,
): Promise<LiveActivitySession[]> {
  const rows = await env.ZW_DB.prepare(
    `SELECT instances.json AS json
     FROM activity_instances AS instances
     JOIN activity_targets AS targets ON targets.activity_instance_id = instances.id
     WHERE targets.target_tenant_id = ?
       AND NOT EXISTS (
         SELECT 1 FROM activity_deliveries AS deliveries
         WHERE deliveries.activity_instance_id = instances.id
           AND deliveries.target_tenant_id = targets.target_tenant_id
       )
     ORDER BY instances.updated_at DESC, instances.id`,
  )
    .bind(tenantId)
    .all<JsonRow>();
  return rows.results.map((row) => parseJson<LiveActivitySession>(row.json));
}
