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

/// One placed widget's push token and the cards it asked for.
export interface WidgetTokenSubscription {
  token: string;
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
  lastDelivery?: WidgetPushDeliveryDiagnostic;
}

export interface WidgetPushDeliveryDiagnostic {
  tokenPrefix?: string;
  attemptedAt: string;
  status: number;
  reason?: string;
  apnsId?: string;
  attempts: number;
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
  // `ON CONFLICT DO UPDATE` rather than `INSERT OR REPLACE`: the latter deletes
  // the existing row and inserts a new one, which D1 bills as two rows written
  // where an update in place is one. Measured against the production database —
  // republishing an existing card cost 2 rows written as `OR REPLACE` and costs
  // 1 this way, out of 6 for the whole request.
  //
  // The two are otherwise the same here. Every non-key column is assigned from
  // `excluded`, so the stored row is still replaced whole and the documented
  // last-write-wins contract is unchanged; `cards` has no triggers and nothing
  // references it, so there is no delete side effect to lose. Updating in place
  // also keeps the rowid stable, which `OR REPLACE` reassigns.
  statements.push(
    env.ZW_DB.prepare(
      `INSERT INTO cards (tenant_id, api_key_hash, id, json, updated_at)
       VALUES (?, ?, ?, ?, ?)
       ON CONFLICT(tenant_id, id) DO UPDATE SET
         api_key_hash = excluded.api_key_hash,
         json = excluded.json,
         updated_at = excluded.updated_at`,
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
  return rows.results.map((row) => parsePublicCard(row.json)).sort(byPriorityThenId);
}

/// Highest priority first, then by id.
///
/// Sorted here rather than in SQL because `priority` lives inside the stored
/// card JSON, and giving it a column of its own would mean an index on a
/// column every upsert writes — D1 bills index maintenance as rows written,
/// and rows written cost 1000x rows read. Every row for the tenant is already
/// in memory by this point, so the comparison is free. The SQL `ORDER BY id`
/// stays: it makes the input deterministic, which is what keeps the sort
/// stable for the cards that set no priority.
export function byPriorityThenId(a: DashboardCard, b: DashboardCard): number {
  const difference = (b.priority ?? 0) - (a.priority ?? 0);
  return difference !== 0 ? difference : a.id.localeCompare(b.id);
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

/// Every widget subscription this tenant holds, one row per placed widget.
///
/// The query does not mention a card, because it cannot: which cards a token
/// wants is stored as JSON in `card_ids_json`. Callers that need this for
/// several cards should read it once and match in memory rather than asking per
/// card — see `collectWidgetPushTargetsForCards`.
export async function listWidgetTokenSubscriptions(
  env: Env,
  tenantId: string,
): Promise<WidgetTokenSubscription[]> {
  const rows = await env.ZW_DB.prepare(
    `SELECT token, card_ids_json, all_cards FROM widget_tokens
     WHERE tenant_id = ?
     ORDER BY device_id, widget_kind`,
  )
    .bind(tenantId)
    .all<WidgetTokenRow>();
  return rows.results.map((row) => {
    if (Number(row.all_cards) === 1) return { token: row.token, cardIds: [], allCards: true };
    try {
      const cardIds = parseJson<unknown>(row.card_ids_json);
      // Unparseable means we cannot tell what it wants, so it gets everything —
      // a widget that silently stops reloading is worse than one that reloads
      // when it need not have.
      if (!Array.isArray(cardIds)) return { token: row.token, cardIds: [], allCards: true };
      return { token: row.token, cardIds: cardIds.map(String), allCards: false };
    } catch {
      return { token: row.token, cardIds: [], allCards: true };
    }
  });
}

/// Whether this subscription wants to hear about `cardId`.
export function subscriptionCoversCard(
  subscription: WidgetTokenSubscription,
  cardId: string,
): boolean {
  return subscription.allCards || subscription.cardIds.includes(cardId);
}

export async function listWidgetTokensForCard(
  env: Env,
  tenantId: string,
  cardId: string,
): Promise<string[]> {
  const subscriptions = await listWidgetTokenSubscriptions(env, tenantId);
  return [
    ...new Set(
      subscriptions
        .filter((subscription) => subscriptionCoversCard(subscription, cardId))
        .map((subscription) => subscription.token),
    ),
  ];
}

export async function putWidgetPushDeliveryDiagnostic(
  env: Env,
  token: string,
  diagnostic: Omit<WidgetPushDeliveryDiagnostic, "attemptedAt"> & { attemptedAt?: string },
): Promise<void> {
  await env.ZW_DB.prepare(
    `INSERT INTO widget_push_delivery_diagnostics
       (token, attempted_at, status, reason, apns_id, attempts)
     VALUES (?, ?, ?, ?, ?, ?)
     ON CONFLICT(token) DO UPDATE SET
       attempted_at = excluded.attempted_at,
       status = excluded.status,
       reason = excluded.reason,
       apns_id = excluded.apns_id,
       attempts = excluded.attempts`,
  )
    .bind(
      token,
      diagnostic.attemptedAt ?? nowIso(),
      diagnostic.status,
      diagnostic.reason ?? null,
      diagnostic.apnsId ?? null,
      diagnostic.attempts,
    )
    .run();
}

export async function listWidgetPushDeliveryDiagnostics(
  env: Env,
  tenantId: string,
): Promise<WidgetPushDeliveryDiagnostic[]> {
  const rows = await env.ZW_DB.prepare(
    `SELECT DISTINCT diagnostics.token, diagnostics.attempted_at, diagnostics.status,
       diagnostics.reason, diagnostics.apns_id, diagnostics.attempts
     FROM widget_push_delivery_diagnostics AS diagnostics
     JOIN widget_tokens AS tokens ON tokens.token = diagnostics.token
     WHERE tokens.tenant_id = ?
     ORDER BY diagnostics.attempted_at DESC`,
  )
    .bind(tenantId)
    .all<{
      token: string;
      attempted_at: string;
      status: number;
      reason: string | null;
      apns_id: string | null;
      attempts: number;
    }>();
  return rows.results.map(deliveryDiagnosticFromRow);
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

/// An activity this tenant can see, and who owns it.
///
/// The owner is carried alongside rather than on the session, because
/// `LiveActivitySession` is the shape rendered on the device and duplicated in
/// Swift — a server-only bookkeeping field does not belong in it.
export interface VisibleActivity {
  session: LiveActivitySession;
  ownerTenantId: string;
}

/// Everything targeted at this tenant: what it owns, plus what other tenants
/// have shared with it. `owner_tenant_id` comes off the same row the join
/// already reads, so telling the two apart costs no extra query.
export async function listActivityInstancesForTarget(
  env: Env,
  targetTenantId: string,
): Promise<VisibleActivity[]> {
  const rows = await env.ZW_DB.prepare(
    `SELECT instances.json AS json, instances.owner_tenant_id AS owner_tenant_id
     FROM activity_instances AS instances
     JOIN activity_targets AS targets ON targets.activity_instance_id = instances.id
     WHERE targets.target_tenant_id = ?
     ORDER BY instances.updated_at DESC, instances.id`,
  )
    .bind(targetTenantId)
    .all<JsonRow & { owner_tenant_id: string }>();
  return rows.results.map((row) => ({
    session: parseJson<LiveActivitySession>(row.json),
    ownerTenantId: row.owner_tenant_id,
  }));
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

export interface EndedActivity {
  activityInstanceId: string;
  externalActivityId: string;
  kind: string;
  title: string;
  finalState?: string;
  finalSubtitle?: string;
  startedAt?: string;
  endedAt: string;
}

/// How long an ended activity stays listable. A Live Activity's own ceiling is
/// 8 hours plus a 4-hour dismissal window, so a day covers everything that
/// could still be recent without turning this into a log.
const ACTIVITY_HISTORY_TTL_SECONDS = 24 * 60 * 60;

export async function recordEndedActivity(
  env: Env,
  tenantId: string,
  entry: EndedActivity,
): Promise<void> {
  const expiresAt = Math.floor(Date.parse(entry.endedAt) / 1000) + ACTIVITY_HISTORY_TTL_SECONDS;
  await env.ZW_DB.prepare(
    `INSERT INTO activity_history
       (tenant_id, activity_instance_id, external_id, kind, title,
        final_state, final_subtitle, started_at, ended_at, expires_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(tenant_id, activity_instance_id) DO UPDATE SET
       final_state = excluded.final_state,
       final_subtitle = excluded.final_subtitle,
       ended_at = excluded.ended_at,
       expires_at = excluded.expires_at`,
  )
    .bind(
      tenantId,
      entry.activityInstanceId,
      entry.externalActivityId,
      entry.kind,
      entry.title,
      entry.finalState ?? null,
      entry.finalSubtitle ?? null,
      entry.startedAt ?? null,
      entry.endedAt,
      expiresAt,
    )
    .run();
}

export async function listEndedActivities(
  env: Env,
  tenantId: string,
  nowSeconds = Math.floor(Date.now() / 1000),
): Promise<EndedActivity[]> {
  const rows = await env.ZW_DB.prepare(
    `SELECT activity_instance_id, external_id, kind, title, final_state,
            final_subtitle, started_at, ended_at
     FROM activity_history
     WHERE tenant_id = ? AND expires_at > ?
     ORDER BY ended_at DESC, activity_instance_id`,
  )
    .bind(tenantId, nowSeconds)
    .all<{
      activity_instance_id: string;
      external_id: string;
      kind: string;
      title: string;
      final_state: string | null;
      final_subtitle: string | null;
      started_at: string | null;
      ended_at: string;
    }>();
  return rows.results.map((row) => ({
    activityInstanceId: row.activity_instance_id,
    externalActivityId: row.external_id,
    kind: row.kind,
    title: row.title,
    ...(row.final_state ? { finalState: row.final_state } : {}),
    ...(row.final_subtitle ? { finalSubtitle: row.final_subtitle } : {}),
    ...(row.started_at ? { startedAt: row.started_at } : {}),
    endedAt: row.ended_at,
  }));
}

/// Reclaims ended activities past their retention window.
///
/// Rides the same sampled sweep as the rate limit buckets, and deletes in
/// bounded chunks for the same reason: `expires_at` carries no index — one
/// would add a second write to the end path — so an unqualified delete would
/// scan, and most expensively in exactly the situation that makes sweeping
/// worth doing. Failures are swallowed; a sweep must never fail the work it
/// rides along with.
export async function sweepExpiredActivityHistory(env: Env): Promise<number> {
  const CHUNK = 200;
  const MAX_CHUNKS = 5;
  let deleted = 0;
  try {
    for (let i = 0; i < MAX_CHUNKS; i++) {
      const result = await env.ZW_DB.prepare(
        `DELETE FROM activity_history WHERE rowid IN (
           SELECT rowid FROM activity_history WHERE expires_at < ? LIMIT ?
         ) RETURNING rowid`,
      )
        .bind(Math.floor(Date.now() / 1000), CHUNK)
        .all<{ rowid: number }>();
      const removed = result.results.length;
      deleted += removed;
      if (removed < CHUNK) break;
    }
  } catch (err) {
    console.warn("activity_history.cleanup_failed", {
      error: err instanceof Error ? err.message : String(err),
    });
  }
  return deleted;
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

export async function getStartTokenForDevice(
  env: Env,
  tenantId: string,
  deviceId: string,
  attributesType: string,
): Promise<string | null> {
  const row = await env.ZW_DB.prepare(
    `SELECT token FROM start_tokens
     WHERE tenant_id = ? AND device_id = ? AND attributes_type = ?`,
  )
    .bind(tenantId, deviceId, attributesType)
    .first<TokenRow>();
  return row?.token ?? null;
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
    `SELECT tokens.api_key_hash, tokens.device_id, tokens.widget_kind,
       tokens.token, tokens.updated_at, tokens.app_version, tokens.platform,
       diagnostics.attempted_at, diagnostics.status, diagnostics.reason,
       diagnostics.apns_id, diagnostics.attempts
     FROM widget_tokens AS tokens
     LEFT JOIN widget_push_delivery_diagnostics AS diagnostics
       ON diagnostics.token = tokens.token
     WHERE tokens.tenant_id = ?
     ORDER BY tokens.api_key_hash, tokens.device_id, tokens.widget_kind`,
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
      attempted_at: string | null;
      status: number | null;
      reason: string | null;
      apns_id: string | null;
      attempts: number | null;
    }>();
  return rows.results.map((row) => ({
    apiKeyHash: row.api_key_hash,
    key: keys.widgetToken(row.api_key_hash, row.device_id, row.widget_kind),
    value: {
      token: row.token,
      updatedAt: row.updated_at,
      appVersion: row.app_version,
      platform: row.platform,
      lastDelivery: row.attempted_at && row.status !== null && row.attempts !== null
        ? deliveryDiagnosticFromRow({
          attempted_at: row.attempted_at,
          status: row.status,
          reason: row.reason,
          apns_id: row.apns_id,
          attempts: row.attempts,
        })
        : undefined,
    },
  }));
}

function deliveryDiagnosticFromRow(row: {
  token?: string;
  attempted_at: string;
  status: number;
  reason: string | null;
  apns_id: string | null;
  attempts: number;
}): WidgetPushDeliveryDiagnostic {
  return {
    ...(row.token ? { tokenPrefix: row.token.slice(0, 8) } : {}),
    attemptedAt: row.attempted_at,
    status: Number(row.status),
    reason: row.reason ?? undefined,
    apnsId: row.apns_id ?? undefined,
    attempts: Number(row.attempts),
  };
}

export async function listTenantActivities(
  env: Env,
  tenantId: string,
): Promise<ScopedEntry<ActivityRecord & { activityInstanceId: string; externalActivityId: string }>[]> {
  const rows = await env.ZW_DB.prepare(
    `SELECT deliveries.api_key_hash AS api_key_hash,
            deliveries.activity_instance_id AS activity_instance_id,
            instances.external_id AS external_id,
            instances.updated_at AS instance_updated_at,
            deliveries.json AS json
     FROM activity_deliveries AS deliveries
     JOIN activity_instances AS instances ON instances.id = deliveries.activity_instance_id
     WHERE deliveries.target_tenant_id = ?
     ORDER BY deliveries.api_key_hash, instances.external_id, deliveries.device_id`,
  )
    .bind(tenantId)
    .all<{
      api_key_hash: string;
      activity_instance_id: string;
      external_id: string;
      instance_updated_at: string;
      json: string;
    }>();
  return rows.results.map((row) => ({
    apiKeyHash: row.api_key_hash,
    key: keys.activity(row.api_key_hash, row.activity_instance_id),
    value: {
      ...parseJson<ActivityRecord>(row.json),
      activityInstanceId: row.activity_instance_id,
      externalActivityId: row.external_id,
      // From the instance, not the delivery. The delivery row is written when a
      // device registers and not touched again, so its own timestamp would show
      // when the device attached rather than when the activity last changed —
      // and the join was already here.
      updatedAt: row.instance_updated_at,
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
