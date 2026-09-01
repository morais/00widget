import {
  ApiScopePresets,
  DEFAULT_TOKEN_LIFETIME_SECONDS,
  sha256Hex,
  type ApiScope,
} from "../src/auth";
import type { Env } from "../src/types";

type FakeRow = Record<string, string>;
// `api_keys.renew_seconds` is a nullable INTEGER, and the number/null
// distinction drives whether a credential renews — so it cannot be flattened
// to a string the way every other column here can.
type FakeApiKeyRow = Record<string, string | number | null>;

class FakeD1Statement {
  constructor(
    private readonly owner: FakeD1,
    private readonly sql: string,
    private readonly values: unknown[] = [],
  ) {}

  bind(...values: unknown[]): FakeD1Statement {
    return new FakeD1Statement(this.owner, this.sql, values);
  }

  async run<T = unknown>(): Promise<D1Result<T>> {
    // A RETURNING statement mutates *and* yields rows, so it is served by the
    // read path and its rows travel back in `results` — that is what `batch`
    // hands the caller, and the rate limiter reads its new counts from there.
    // A batched SELECT reaches `run()` too, and real D1 answers it with rows —
    // `batch` returns a result per statement whatever each one is. Route
    // anything that yields rows to the read path, not just RETURNING writes.
    if (/\bRETURNING\b/i.test(this.sql) || /^\s*SELECT\b/i.test(this.sql)) {
      const results = this.owner.all(this.sql, this.values) as T[];
      return { results, success: true, meta: { changes: results.length } } as D1Result<T>;
    }
    const changes = this.owner.run(this.sql, this.values);
    return { success: true, meta: { changes } } as D1Result<T>;
  }

  async first<T = unknown>(): Promise<T | null> {
    const rows = this.owner.all(this.sql, this.values);
    return (rows[0] as T | undefined) ?? null;
  }

  async all<T = unknown>(): Promise<D1Result<T>> {
    return { results: this.owner.all(this.sql, this.values) as T[], success: true, meta: {} } as D1Result<T>;
  }
}

export class FakeD1 {
  private tenants = new Map<string, FakeRow>();
  private apiKeys = new Map<string, FakeApiKeyRow>();
  private cards = new Map<string, FakeRow>();
  private actionPayloads = new Map<string, FakeRow>();
  private devices = new Map<string, FakeRow>();
  private widgetTokens = new Map<string, FakeRow>();
  private activities = new Map<string, FakeRow>();
  private pendingActivities = new Map<string, FakeRow>();
  private activityInstances = new Map<string, FakeRow>();
  private activityTargets = new Map<string, FakeRow>();
  private activityDeliveries = new Map<string, FakeRow>();
  private startTokens = new Map<string, FakeRow>();
  private appleAccounts = new Map<string, FakeRow>();
  private webhookIntegrations = new Map<string, FakeRow>();
  private shares = new Map<string, FakeRow>();
  private rateLimitBuckets = new Map<string, FakeRow>();
  private widgetPushCadence = new Map<string, FakeRow>();
  private widgetPushPending = new Map<string, FakeRow>();
  private widgetPushDeliveryDiagnostics = new Map<string, FakeApiKeyRow>();
  private subscriptions = new Map<string, FakeApiKeyRow>();
  private activityHistory = new Map<string, FakeApiKeyRow>();
  private mcpAuthorizationCodes = new Map<string, FakeApiKeyRow>();

  prepare(sql: string): D1PreparedStatement {
    return new FakeD1Statement(this, sql) as unknown as D1PreparedStatement;
  }

  async batch<T = unknown>(statements: D1PreparedStatement[]): Promise<D1Result<T>[]> {
    const results: D1Result<T>[] = [];
    for (const statement of statements) {
      results.push(await statement.run<T>());
    }
    return results;
  }

  seedApiKeyHash(
    rawTokenHash: string,
    tenantId = "test-tenant",
    label = "test key",
    kind: "publisher" | "app" = "publisher",
    sessionId = "",
    deviceId = "",
    expiresAt = "2099-01-01T00:00:00.000Z",
    scopes: readonly ApiScope[] = kind === "app"
      ? ApiScopePresets.appOnly
      : ApiScopePresets.legacyPublisher,
    // Mirrors what `createApiKey` writes. Pass null for a fixed-deadline key.
    renewSeconds: number | null = DEFAULT_TOKEN_LIFETIME_SECONDS,
    purpose: "general" | "device" | "app" | "agent" | "connector" | "guest" = kind === "app"
      ? "app"
      : "general",
  ): void {
    const now = "2026-01-01T00:00:00.000Z";
    if (!this.tenants.has(tenantId)) {
      this.tenants.set(tenantId, {
        id: tenantId,
        name: tenantId,
        owner_email: `${tenantId}@example.com`,
        created_at: now,
        disabled_at: "",
      });
    }
    this.apiKeys.set(`key:${rawTokenHash}`, {
      id: `key-${rawTokenHash.slice(0, 8)}`,
      tenant_id: tenantId,
      token_hash: rawTokenHash,
      label,
      created_at: now,
      last_used_at: "",
      revoked_at: "",
      kind,
      purpose,
      session_id: sessionId,
      device_id: deviceId,
      expires_at: expiresAt,
      scopes_json: JSON.stringify(scopes),
      renew_seconds: renewSeconds,
    });
  }

  private deleteGuestKeys(matches: (row: FakeApiKeyRow) => boolean): number {
    let removed = 0;
    for (const [key, row] of [...this.apiKeys.entries()]) {
      if (row.kind !== "guest" || !matches(row)) continue;
      this.apiKeys.delete(key);
      removed += 1;
    }
    return removed;
  }

  /// Seeds live guest credentials directly, so the standing-total cap can be
  /// tested without minting through a daily rate limit set lower than it.
  seedGuestKeys(tenantId: string, count: number): void {
    for (let i = 0; i < count; i++) {
      this.apiKeys.set(`seeded-guest-${tenantId}-${i}`, {
        id: `seeded-guest-${tenantId}-${i}`,
        tenant_id: tenantId,
        token_hash: `seeded-guest-hash-${tenantId}-${i}`,
        label: "seeded guest",
        created_at: "2026-01-01T00:00:00.000Z",
        last_used_at: "",
        revoked_at: "",
        kind: "guest",
        purpose: "guest",
        session_id: "",
        device_id: "",
        expires_at: "2099-01-01T00:00:00.000Z",
        scopes_json: JSON.stringify(["guest:read"]),
        renew_seconds: null,
        resource_kind: "card",
        resource_id: "washer",
      });
    }
  }

  /// Backdates a credential's expiry so pruning and expiry paths are testable
  /// without waiting.
  expireApiKey(id: string, expiresAt: string): void {
    const row = this.findApiKeyById(id);
    if (row) row.expires_at = expiresAt;
  }

  // `WHERE id = ?` matches the column, not this Map's key. Rows inserted by
  // `createApiKey` are keyed by id, but `seedApiKeyHash` keys by token hash —
  // a `.get(id)` silently misses those and the statement becomes a no-op.
  private findApiKeyById(id: string): FakeApiKeyRow | undefined {
    return [...this.apiKeys.values()].find((candidate) => candidate.id === id);
  }

  private deleteExpiredRateLimitBuckets(values: unknown[]): number {
    const [now, limit] = values.map(Number);
    let count = 0;
    for (const [key, row] of this.rateLimitBuckets.entries()) {
      if (count >= limit) break;
      if (Number(row.expires_at) < now) {
        this.rateLimitBuckets.delete(key);
        count++;
      }
    }
    return count;
  }

  // Binds as (bucket_key, window_start, weight, expires_at, weight): the weight
  // appears twice because the statement names it once in VALUES and once in the
  // ON CONFLICT increment. Keep this aligned with the statement in
  // `incrementRateLimitBuckets` — reading a value from the wrong position here
  // is invisible, since this class enforces no types and no constraints.
  // Returns the new generation, which is what `RETURNING generation` yields and
  // what `enqueuePendingWidgetReload` reads to decide whether it created the row
  // and therefore owes a queue message.
  private upsertWidgetPushPending(values: unknown[]): number {
    const [tenant_id, queued_at] = values.map(String);
    const existing = this.widgetPushPending.get(tenant_id);
    const generation = Number(existing?.generation ?? 0) + 1;
    this.widgetPushPending.set(tenant_id, {
      tenant_id,
      generation: String(generation),
      queued_at,
    });
    return generation;
  }

  private upsertRateLimitBucket(values: unknown[]): number {
    const [bucket_key, window_start, weight, expires_at] = [
      String(values[0]),
      String(values[1]),
      Number(values[2]),
      String(values[3]),
    ];
    const key = `${bucket_key}:${window_start}`;
    const existing = this.rateLimitBuckets.get(key);
    const count = Number(existing?.count ?? 0) + weight;
    this.rateLimitBuckets.set(key, {
      bucket_key,
      window_start,
      count: String(count),
      expires_at,
    });
    return count;
  }

  run(sql: string, values: unknown[]): number {
    const normalized = normalizeSql(sql);
    // The account-deletion batch in `src/account.ts`: one table, one equality,
    // one bound value. Matched by shape rather than listed statement by
    // statement — and deliberately *first*, because several handlers below
    // match on a prefix like "DELETE FROM cards" and would swallow a
    // tenant-wide delete, read the missing second bind as undefined, delete
    // nothing, and still report a change. The single-value guard is what keeps
    // it from claiming any of their narrower statements.
    const accountWipe = values.length === 1
      ? /^DELETE FROM (\w+) WHERE (tenant_id|owner_tenant_id|target_tenant_id|recipient_tenant_id|token|id) = \?$/.exec(
          normalized,
        )
      : null;
    if (accountWipe) {
      const [, table, column] = accountWipe;
      const rows = this.tableRows(table);
      if (rows) {
        const [value] = values.map(String);
        let removed = 0;
        for (const [key, row] of [...rows.entries()]) {
          if (String((row as Record<string, unknown>)[column] ?? "") !== value) continue;
          rows.delete(key);
          removed++;
        }
        return removed;
      }
    }
    // Models tenants_by_owner_email_unique (migrations/0030) as well as the
    // primary key, because `OR IGNORE` swallows both the same way — it returns
    // changes=0 and writes nothing, which is exactly what createApiKey and
    // createTenantForOwner now read to detect a refused address. Without the
    // constraint here the fake would report success where D1 reports nothing,
    // and the error path would be untestable.
    if (normalized.startsWith("INSERT OR IGNORE INTO tenants")) {
      const [id, name, owner_email, created_at] = values.map(String);
      if (this.tenants.has(id)) return 0;
      // Partial index: NULL and '' addresses are outside it, and a disabled
      // tenant releases its address.
      const claimed = owner_email
        && [...this.tenants.values()].some(
          (tenant) => !tenant.disabled_at
            && tenant.owner_email
            && tenant.owner_email.toLowerCase() === owner_email.toLowerCase(),
        );
      if (claimed) return 0;
      this.tenants.set(id, { id, name, owner_email, created_at, disabled_at: "" });
      return 1;
    }
    if (normalized.startsWith("UPDATE tenants SET owner_email = ? WHERE id = ?")) {
      const [owner_email, id] = values.map(String);
      const row = this.tenants.get(id);
      if (!row || row.owner_email) return 0;
      row.owner_email = owner_email;
      return 1;
    }
    if (normalized.startsWith("INSERT INTO api_keys")) {
      const [
        id,
        tenant_id,
        token_hash,
        label,
        created_at,
        kind,
        purpose,
        session_id,
        device_id,
        expires_at,
        scopes_json,
      ] = values.map((value) => value == null ? "" : String(value));
      // Read straight from `values` so the number/null distinction survives the
      // String() mapping above — NULL here means "fixed deadline, never renew".
      const renew_seconds = typeof values[11] === "number" ? values[11] : null;
      // api_keys.kind carries a CHECK constraint in the real schema. This fake
      // enforces no constraints, which is how a guest kind reached production
      // against a CHECK that still read ('publisher', 'app') and 500'd every
      // mint. Mirror it here so the suite fails instead of the deployment.
      if (!["publisher", "app", "guest"].includes(kind)) {
        throw new Error(`CHECK constraint failed: kind IN ('publisher','app','guest') — got ${kind}`);
      }
      // Guest links bind a credential to one resource; NULL for every other kind.
      const resource_kind = values[12] == null ? "" : String(values[12]);
      const resource_id = values[13] == null ? "" : String(values[13]);
      this.apiKeys.set(id, {
        id,
        tenant_id,
        token_hash,
        label,
        created_at,
        last_used_at: "",
        revoked_at: "",
        kind,
        purpose,
        session_id,
        device_id,
        expires_at,
        scopes_json,
        renew_seconds,
        resource_kind,
        resource_id,
      });
      return 1;
    }
    if (normalized.startsWith("INSERT INTO apple_accounts")) {
      const [apple_sub, tenant_id, email, created_at, updated_at] = values.map(String);
      const existing = this.appleAccounts.get(apple_sub);
      this.appleAccounts.set(apple_sub, {
        apple_sub,
        tenant_id,
        email,
        created_at: existing?.created_at ?? created_at,
        updated_at,
      });
      return 1;
    }
    if (normalized.startsWith("UPDATE api_keys SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL")) {
      const [revoked_at, id] = values.map(String);
      const row = [...this.apiKeys.values()].find((candidate) => candidate.id === id);
      if (!row || row.revoked_at) return 0;
      row.revoked_at = revoked_at;
      return 1;
    }
    if (normalized === "UPDATE api_keys SET revoked_at = ? WHERE tenant_id = ? AND session_id = ? AND revoked_at IS NULL") {
      const [revoked_at, tenant_id, session_id] = values.map(String);
      let count = 0;
      for (const row of this.apiKeys.values()) {
        if (row.tenant_id === tenant_id && row.session_id === session_id && !row.revoked_at) {
          row.revoked_at = revoked_at;
          count++;
        }
      }
      return count;
    }
    if (normalized === "UPDATE api_keys SET revoked_at = ? WHERE tenant_id = ? AND kind = 'publisher' AND purpose = 'agent' AND id <> ? AND revoked_at IS NULL") {
      const [revoked_at, tenant_id, excluded_id] = values.map(String);
      let count = 0;
      for (const row of this.apiKeys.values()) {
        if (row.tenant_id === tenant_id
          && row.kind === "publisher"
          && row.purpose === "agent"
          && row.id !== excluded_id
          && !row.revoked_at) {
          row.revoked_at = revoked_at;
          count++;
        }
      }
      return count;
    }
    if (normalized.startsWith("UPDATE api_keys SET last_used_at = ?, expires_at = MAX(expires_at, ?) WHERE id = ? AND revoked_at IS NULL")) {
      const [last_used_at, renewed_to, id] = values.map(String);
      const row = this.findApiKeyById(id);
      if (!row || row.revoked_at) return 0;
      row.last_used_at = last_used_at;
      // SQLite's scalar MAX() over two ISO-8601 UTC strings is a lexicographic
      // comparison, which for this fixed format is also chronological.
      const current = String(row.expires_at ?? "");
      row.expires_at = renewed_to > current ? renewed_to : current;
      return 1;
    }
    if (normalized.startsWith("UPDATE api_keys SET last_used_at = ? WHERE id = ? AND revoked_at IS NULL")) {
      const [last_used_at, id] = values.map(String);
      const row = this.findApiKeyById(id);
      if (!row || row.revoked_at) return 0;
      row.last_used_at = last_used_at;
      return 1;
    }
    // `INSERT ... ON CONFLICT(tenant_id, id) DO UPDATE`, which replaces the row
    // whole exactly as `INSERT OR REPLACE` did — it is one row written against
    // D1 rather than two. Same five bound values, same order.
    if (normalized.startsWith("INSERT INTO cards")) {
      const [tenant_id, api_key_hash, id, json, updated_at] = values.map(String);
      this.cards.set(`${tenant_id}:${id}`, { tenant_id, api_key_hash, id, json, updated_at });
      return 1;
    }
    if (normalized.startsWith("INSERT OR REPLACE INTO action_payloads")) {
      const [tenant_id, api_key_hash, card_id, action_id, json, updated_at] = values.map(String);
      this.actionPayloads.set(`${tenant_id}:${card_id}:${action_id}`, {
        tenant_id,
        api_key_hash,
        card_id,
        action_id,
        json,
        updated_at,
      });
      return 1;
    }
    if (normalized === "DELETE FROM action_payloads WHERE tenant_id = ? AND card_id = ?") {
      const [tenant_id, card_id] = values.map(String);
      let count = 0;
      for (const [key, row] of this.actionPayloads.entries()) {
        if (row.tenant_id === tenant_id && row.card_id === card_id) {
          this.actionPayloads.delete(key);
          count++;
        }
      }
      return count;
    }
    if (normalized.startsWith("INSERT OR REPLACE INTO webhook_integrations")) {
      const [tenant_id, api_key_hash, json, updated_at] = values.map(String);
      this.webhookIntegrations.set(tenant_id, { tenant_id, api_key_hash, json, updated_at });
      return 1;
    }
    if (normalized.startsWith("INSERT OR REPLACE INTO devices")) {
      const [tenant_id, api_key_hash, device_id, json, updated_at] = values.map(String);
      this.devices.set(`${tenant_id}:${device_id}`, {
        tenant_id,
        api_key_hash,
        device_id,
        json,
        updated_at,
      });
      return 1;
    }
    if (normalized.startsWith("INSERT OR REPLACE INTO widget_tokens")) {
      const [
        tenant_id,
        api_key_hash,
        device_id,
        widget_kind,
        token,
        updated_at,
        card_ids_json = "[]",
        all_cards = "1",
        app_version = "0.0",
        platform = "ios",
      ] = values.map(String);
      this.widgetTokens.set(`${tenant_id}:${device_id}:${widget_kind}`, {
        tenant_id,
        api_key_hash,
        device_id,
        widget_kind,
        token,
        updated_at,
        card_ids_json,
        all_cards,
        app_version,
        platform,
      });
      return 1;
    }
    if (normalized.startsWith("INSERT OR REPLACE INTO activities")) {
      const [tenant_id, api_key_hash, external_id, device_id, json, updated_at] = values.map(String);
      this.activities.set(`${tenant_id}:${external_id}:${device_id}`, {
        tenant_id,
        api_key_hash,
        external_id,
        device_id,
        json,
        updated_at,
      });
      return 1;
    }
    if (normalized.startsWith("INSERT INTO activity_instances")) {
      const [id, owner_tenant_id, api_key_hash, external_id, kind, json, updated_at] =
        values.map(String);
      this.activityInstances.set(id, {
        id,
        owner_tenant_id,
        api_key_hash,
        external_id,
        kind,
        json,
        updated_at,
      });
      return 1;
    }
    if (normalized.startsWith("INSERT OR REPLACE INTO activity_targets")) {
      const [activity_instance_id, owner_tenant_id, target_tenant_id, shareValue, created_at] = values;
      const share_id = shareValue == null ? "" : String(shareValue);
      this.activityTargets.set(`${activity_instance_id}:${target_tenant_id}`, {
        activity_instance_id: String(activity_instance_id),
        owner_tenant_id: String(owner_tenant_id),
        target_tenant_id: String(target_tenant_id),
        share_id,
        created_at: String(created_at),
      });
      return 1;
    }
    if (normalized.startsWith("INSERT OR REPLACE INTO activity_deliveries")) {
      const [activity_instance_id, owner_tenant_id, target_tenant_id, shareValue,
        api_key_hash, device_id, json, updated_at] = values;
      const share_id = shareValue == null ? "" : String(shareValue);
      this.activityDeliveries.set(`${activity_instance_id}:${target_tenant_id}:${device_id}`, {
        activity_instance_id: String(activity_instance_id),
        owner_tenant_id: String(owner_tenant_id),
        target_tenant_id: String(target_tenant_id),
        share_id,
        api_key_hash: String(api_key_hash),
        device_id: String(device_id),
        json: String(json),
        updated_at: String(updated_at),
      });
      return 1;
    }
    if (normalized.startsWith("INSERT OR REPLACE INTO pending_activities")) {
      const [tenant_id, api_key_hash, external_id, json, updated_at] = values.map(String);
      this.pendingActivities.set(`${tenant_id}:${external_id}`, {
        tenant_id,
        api_key_hash,
        external_id,
        json,
        updated_at,
      });
      return 1;
    }
    if (normalized.startsWith("INSERT OR REPLACE INTO start_tokens")) {
      const [tenant_id, api_key_hash, device_id, attributes_type, token, updated_at] =
        values.map(String);
      this.startTokens.set(`${tenant_id}:${device_id}:${attributes_type}`, {
        tenant_id,
        api_key_hash,
        device_id,
        attributes_type,
        token,
        updated_at,
      });
      return 1;
    }
    if (normalized.startsWith("DELETE FROM cards")) {
      const [tenant_id, id] = values.map(String);
      this.cards.delete(`${tenant_id}:${id}`);
      return 1;
    }
    const registrationCleanup = /^DELETE FROM (devices|widget_tokens|activities|start_tokens) WHERE tenant_id = \? AND (api_key_hash|device_id) = \?$/.exec(normalized);
    if (registrationCleanup) {
      const [, table, field] = registrationCleanup;
      const [tenant_id, value] = values.map(String);
      const rows = table === "devices"
        ? this.devices
        : table === "widget_tokens"
          ? this.widgetTokens
          : table === "activities"
            ? this.activities
            : this.startTokens;
      let count = 0;
      for (const [key, row] of rows.entries()) {
        if (row.tenant_id === tenant_id && row[field] === value) {
          rows.delete(key);
          count++;
        }
      }
      return count;
    }
    if (normalized === "DELETE FROM activity_deliveries WHERE target_tenant_id = ? AND api_key_hash = ?" ||
        normalized === "DELETE FROM activity_deliveries WHERE target_tenant_id = ? AND device_id = ?") {
      const [target_tenant_id, value] = values.map(String);
      const field = normalized.includes("api_key_hash") ? "api_key_hash" : "device_id";
      let count = 0;
      for (const [key, row] of this.activityDeliveries.entries()) {
        if (row.target_tenant_id === target_tenant_id && row[field] === value) {
          this.activityDeliveries.delete(key);
          count++;
        }
      }
      return count;
    }
    if (normalized === "DELETE FROM activity_deliveries WHERE share_id = ?" ||
        normalized === "DELETE FROM activity_targets WHERE share_id = ?") {
      const [share_id] = values.map(String);
      const rows = normalized.includes("deliveries")
        ? this.activityDeliveries
        : this.activityTargets;
      let count = 0;
      for (const [key, row] of rows.entries()) {
        if (row.share_id === share_id) {
          rows.delete(key);
          count++;
        }
      }
      return count;
    }
    if (normalized === "DELETE FROM activity_deliveries WHERE activity_instance_id = ?" ||
        normalized === "DELETE FROM activity_targets WHERE activity_instance_id = ?") {
      const [activity_instance_id] = values.map(String);
      const rows = normalized.includes("deliveries")
        ? this.activityDeliveries
        : this.activityTargets;
      let count = 0;
      for (const [key, row] of rows.entries()) {
        if (row.activity_instance_id === activity_instance_id) {
          rows.delete(key);
          count++;
        }
      }
      return count;
    }
    if (normalized === "DELETE FROM activity_instances WHERE id = ?") {
      const [id] = values.map(String);
      return this.activityInstances.delete(id) ? 1 : 0;
    }
    if (normalized.startsWith("DELETE FROM webhook_integrations")) {
      const [tenant_id] = values.map(String);
      this.webhookIntegrations.delete(tenant_id);
      return 1;
    }
    if (normalized.startsWith("DELETE FROM activities")) {
      const [tenant_id, external_id] = values.map(String);
      let count = 0;
      for (const [key, row] of this.activities.entries()) {
        if (row.tenant_id === tenant_id && row.external_id === external_id) {
          this.activities.delete(key);
          count++;
        }
      }
      return count;
    }
    if (normalized.startsWith("DELETE FROM pending_activities")) {
      const [tenant_id, external_id] = values.map(String);
      this.pendingActivities.delete(`${tenant_id}:${external_id}`);
      return 1;
    }
    if (normalized === "DELETE FROM widget_tokens WHERE tenant_id = ? AND device_id = ?") {
      const [tenant_id, device_id] = values.map(String);
      let count = 0;
      for (const [key, row] of this.widgetTokens.entries()) {
        if (row.tenant_id === tenant_id && row.device_id === device_id) {
          this.widgetTokens.delete(key);
          count++;
        }
      }
      return count;
    }
    if (normalized === "DELETE FROM widget_tokens WHERE tenant_id = ? AND token = ?") {
      const [tenant_id, token] = values.map(String);
      let count = 0;
      for (const [key, row] of this.widgetTokens.entries()) {
        if (row.tenant_id === tenant_id && row.token === token) {
          this.widgetTokens.delete(key);
          count++;
        }
      }
      return count;
    }
    if (normalized === "DELETE FROM widget_tokens WHERE tenant_id = ? AND token = ? AND device_id <> ?") {
      const [tenant_id, token, device_id] = values.map(String);
      let count = 0;
      for (const [key, row] of this.widgetTokens.entries()) {
        if (
          row.tenant_id === tenant_id &&
          row.token === token &&
          row.device_id !== device_id
        ) {
          this.widgetTokens.delete(key);
          count++;
        }
      }
      return count;
    }
    if (normalized.startsWith("DELETE FROM widget_tokens")) {
      const [tenant_id, device_id, widget_kind] = values.map(String);
      this.widgetTokens.delete(`${tenant_id}:${device_id}:${widget_kind}`);
      return 1;
    }
    if (normalized.startsWith("DELETE FROM start_tokens WHERE tenant_id = ? AND attributes_type = ? AND token = ?")) {
      const [tenant_id, attributes_type, token] = values.map(String);
      let count = 0;
      for (const [key, row] of this.startTokens.entries()) {
        if (row.tenant_id === tenant_id && row.attributes_type === attributes_type && row.token === token) {
          this.startTokens.delete(key);
          count++;
        }
      }
      return count;
    }
    if (normalized.startsWith("DELETE FROM start_tokens")) {
      const [tenant_id, device_id, attributes_type] = values.map(String);
      this.startTokens.delete(`${tenant_id}:${device_id}:${attributes_type}`);
      return 1;
    }
    if (normalized.startsWith("INSERT INTO shares")) {
      const [
        id,
        owner_tenant_id,
        recipient_tenant_id,
        recipient_email,
        resource_kind,
        resource_id,
        created_at,
      ] = [
        String(values[0]),
        String(values[1]),
        values[2] == null ? "" : String(values[2]),
        String(values[3]),
        String(values[4]),
        String(values[5]),
        String(values[6]),
      ];
      this.shares.set(id, {
        id,
        owner_tenant_id,
        recipient_tenant_id,
        recipient_email,
        resource_kind,
        resource_id,
        status: "pending",
        created_at,
        accepted_at: "",
        revoked_at: "",
      });
      return 1;
    }
    if (normalized.startsWith("UPDATE shares SET status = 'accepted'")) {
      const [recipient_tenant_id, accepted_at, id] = values.map(String);
      const row = this.shares.get(id);
      if (!row) return 0;
      row.status = "accepted";
      row.recipient_tenant_id = recipient_tenant_id;
      row.accepted_at = accepted_at;
      return 1;
    }
    if (normalized.startsWith("UPDATE shares SET status = 'declined'")) {
      const [id] = values.map(String);
      const row = this.shares.get(id);
      if (!row) return 0;
      row.status = "declined";
      return 1;
    }
    if (normalized.startsWith("UPDATE shares SET status = 'revoked', revoked_at = ? WHERE id = ?")) {
      const [revoked_at, id] = values.map(String);
      const row = this.shares.get(id);
      if (!row) return 0;
      row.status = "revoked";
      row.revoked_at = revoked_at;
      return 1;
    }
    if (
      normalized.startsWith(
        "UPDATE shares SET status = 'revoked', revoked_at = ? WHERE owner_tenant_id = ? AND resource_kind = 'card' AND resource_id = ?",
      )
    ) {
      const [revoked_at, owner_tenant_id, resource_id] = values.map(String);
      let count = 0;
      for (const row of this.shares.values()) {
        if (
          row.owner_tenant_id === owner_tenant_id &&
          row.resource_kind === "card" &&
          row.resource_id === resource_id &&
          (row.status === "pending" || row.status === "accepted")
        ) {
          row.status = "revoked";
          row.revoked_at = revoked_at;
          count++;
        }
      }
      return count;
    }
    if (normalized === "DELETE FROM api_keys WHERE kind = 'guest' AND expires_at < ?") {
      const [expiredBefore] = values.map(String);
      return this.deleteGuestKeys((row) => String(row.expires_at) < expiredBefore);
    }
    if (normalized === "DELETE FROM api_keys WHERE kind = 'guest' AND revoked_at IS NOT NULL AND revoked_at < ?") {
      const [revokedBefore] = values.map(String);
      return this.deleteGuestKeys((row) => !!row.revoked_at && String(row.revoked_at) < revokedBefore);
    }
    if (normalized === "DELETE FROM rate_limit_buckets WHERE bucket_key = ? AND window_start < ?") {
      const [bucket_key, window_start] = [String(values[0]), Number(values[1])];
      let count = 0;
      for (const [key, row] of this.rateLimitBuckets.entries()) {
        if (row.bucket_key === bucket_key && Number(row.window_start) < window_start) {
          this.rateLimitBuckets.delete(key);
          count++;
        }
      }
      return count;
    }
    if (normalized.startsWith("DELETE FROM rate_limit_buckets WHERE rowid IN")) {
      return this.deleteExpiredRateLimitBuckets(values);
    }
    if (normalized.startsWith("INSERT INTO rate_limit_buckets")) {
      this.upsertRateLimitBucket(values);
      return 1;
    }
    if (normalized.startsWith("INSERT INTO widget_push_cadence")) {
      // Mirrors the real conditional upsert: a token bucket that refills by
      // elapsed time, plus a hard minimum spacing.
      const key = String(values[0]);
      // Positions, not names: the real statement uses anonymous placeholders
      // and binds each value once per appearance, so this mirrors that order.
      // (token, now, burst | burst, now, refill, now | now, spacing | burst,
      // now, refill)
      const now = Number(values[1]);
      const burst = Number(values[2]);
      const refill = Number(values[5]);
      const minSpacing = Number(values[8]);
      const existing = this.widgetPushCadence.get(key);
      if (!existing) {
        this.widgetPushCadence.set(key, {
          token: key,
          last_sent_at: String(now),
          allowance: String(burst - 1),
        });
        return 1;
      }
      const elapsed = now - Number(existing.last_sent_at);
      if (elapsed < minSpacing) return 0;
      const allowance = Math.min(burst, Number(existing.allowance) + elapsed / refill);
      if (allowance < 1) return 0;
      this.widgetPushCadence.set(key, {
        token: key,
        last_sent_at: String(now),
        allowance: String(allowance - 1),
      });
      return 1;
    }
    if (normalized.startsWith("INSERT INTO widget_push_pending")) {
      this.upsertWidgetPushPending(values);
      return 1;
    }
    if (normalized.startsWith("INSERT INTO widget_push_delivery_diagnostics")) {
      const [token, attempted_at, status, reason, apns_id, attempts] = values;
      this.widgetPushDeliveryDiagnostics.set(String(token), {
        token: String(token),
        attempted_at: String(attempted_at),
        status: Number(status),
        reason: reason === null ? null : String(reason),
        apns_id: apns_id === null ? null : String(apns_id),
        attempts: Number(attempts),
      });
      return 1;
    }
    if (normalized.startsWith("DELETE FROM widget_push_pending")) {
      const [tenant_id, generation] = values.map(String);
      const existing = this.widgetPushPending.get(tenant_id);
      if (!existing || existing.generation !== generation) return 0;
      this.widgetPushPending.delete(tenant_id);
      return 1;
    }
    if (normalized.startsWith("INSERT INTO activity_history")) {
      const [
        tenant_id, activity_instance_id, external_id, kind, title,
        final_state, final_subtitle, started_at, ended_at, expires_at,
      ] = values;
      this.activityHistory.set(`${String(tenant_id)}:${String(activity_instance_id)}`, {
        tenant_id: String(tenant_id),
        activity_instance_id: String(activity_instance_id),
        external_id: String(external_id),
        kind: String(kind),
        title: String(title),
        final_state: final_state === null ? null : String(final_state),
        final_subtitle: final_subtitle === null ? null : String(final_subtitle),
        started_at: started_at === null ? null : String(started_at),
        ended_at: String(ended_at),
        expires_at: Number(expires_at),
      });
      return 1;
    }
    if (normalized.startsWith("DELETE FROM activity_history WHERE expires_at")) {
      const cutoff = Number(values[0]);
      let removed = 0;
      for (const [key, row] of [...this.activityHistory]) {
        if (Number(row.expires_at) <= cutoff) {
          this.activityHistory.delete(key);
          removed++;
        }
      }
      return removed;
    }
    if (normalized.startsWith("INSERT INTO subscriptions")) {
      return this.upsertSubscription(values);
    }
    if (normalized.startsWith("UPDATE subscriptions SET tenant_id = ?, updated_at = ? WHERE original_transaction_id = ? AND tenant_id IS NULL")) {
      const [tenant_id, updated_at, original_transaction_id] = values.map(String);
      const row = this.subscriptions.get(original_transaction_id);
      if (!row || row.tenant_id) return 0;
      this.subscriptions.set(original_transaction_id, { ...row, tenant_id, updated_at });
      return 1;
    }
    // Mirrors applyRenewalInfo's UPDATE, bind order and all:
    //   auto_renew, grace_expires_at_ms, updated_at, original_transaction_id,
    //   signed_date_ms
    // The trailing `AND ? >= signed_date_ms` is the ordering guard, and it has
    // to be modelled here or a replayed older notification passes the suite
    // while D1 correctly refuses it. Matched on the whole statement rather than
    // a prefix, so the next clause added to it fails loudly instead of being
    // silently ignored the way this one was.
    if (normalized === "UPDATE subscriptions SET auto_renew = ?, grace_expires_at_ms = ?, updated_at = ? WHERE original_transaction_id = ? AND ? >= signed_date_ms") {
      const [auto_renew, grace_expires_at_ms, updated_at, original_transaction_id, signed_date_ms] = values;
      const row = this.subscriptions.get(String(original_transaction_id));
      if (!row) return 0;
      if (Number(signed_date_ms) < Number(row.signed_date_ms ?? 0)) return 0;
      this.subscriptions.set(String(original_transaction_id), {
        ...row,
        auto_renew: Number(auto_renew),
        grace_expires_at_ms: grace_expires_at_ms === null ? null : Number(grace_expires_at_ms),
        updated_at: String(updated_at),
      });
      return 1;
    }
    // Mirrors claimAuthorizationCode in mcpOAuth.ts. INSERT OR IGNORE makes the
    // check and the claim one statement, so `changes` is what says whether this
    // caller won the race — modelled here as "was the key already present".
    if (normalized === "INSERT OR IGNORE INTO mcp_authorization_codes (jti, redeemed_at, expires_at) VALUES (?, ?, ?)") {
      const [jti, redeemed_at, expires_at] = values;
      const key = String(jti);
      if (this.mcpAuthorizationCodes.has(key)) return 0;
      this.mcpAuthorizationCodes.set(key, {
        jti: key,
        redeemed_at: String(redeemed_at),
        expires_at: Number(expires_at),
      } as unknown as FakeApiKeyRow);
      return 1;
    }
    if (normalized.startsWith("DELETE FROM mcp_authorization_codes WHERE rowid IN")) {
      const [cutoff] = values;
      let removed = 0;
      for (const [key, row] of [...this.mcpAuthorizationCodes.entries()]) {
        if (Number((row as any).expires_at) < Number(cutoff)) {
          this.mcpAuthorizationCodes.delete(key);
          removed++;
        }
      }
      return removed;
    }
    if (normalized === "DELETE FROM shares WHERE lower(recipient_email) = ?") {
      const [email] = values.map(String);
      let removed = 0;
      for (const [key, row] of [...this.shares.entries()]) {
        if (String(row.recipient_email ?? "").toLowerCase() !== email) continue;
        this.shares.delete(key);
        removed++;
      }
      return removed;
    }
    if (normalized === "UPDATE subscriptions SET tenant_id = NULL, updated_at = ? WHERE tenant_id = ?") {
      const [updated_at, tenant_id] = values.map(String);
      let changed = 0;
      for (const row of this.subscriptions.values()) {
        if (String(row.tenant_id ?? "") !== tenant_id) continue;
        row.tenant_id = null;
        row.updated_at = updated_at;
        changed++;
      }
      return changed;
    }
    throw new Error(`Unhandled FakeD1 run SQL: ${normalized}`);
  }

  /// Table name to backing store, for statements the fake matches by shape.
  /// Only the tables the account-deletion batch touches are listed; anything
  /// else falls through to its own handler or to the unhandled-SQL error.
  private tableRows(table: string): Map<string, Record<string, unknown>> | undefined {
    const stores: Record<string, Map<string, unknown>> = {
      tenants: this.tenants,
      api_keys: this.apiKeys,
      apple_accounts: this.appleAccounts,
      cards: this.cards,
      action_payloads: this.actionPayloads,
      devices: this.devices,
      widget_tokens: this.widgetTokens,
      start_tokens: this.startTokens,
      webhook_integrations: this.webhookIntegrations,
      activity_history: this.activityHistory,
      widget_push_pending: this.widgetPushPending,
      widget_push_cadence: this.widgetPushCadence,
      widget_push_delivery_diagnostics: this.widgetPushDeliveryDiagnostics,
      activity_instances: this.activityInstances,
      activity_targets: this.activityTargets,
      activity_deliveries: this.activityDeliveries,
      shares: this.shares,
    };
    return stores[table] as Map<string, Record<string, unknown>> | undefined;
  }

  // Mirrors the ON CONFLICT clause in recordTransaction: an existing tenant_id
  // is never cleared, and a payload older than the stored one is dropped.
  private upsertSubscription(values: unknown[]): number {
    const [
      original_transaction_id, tenant_id, product_id, status, expires_at_ms,
      grace_expires_at_ms, is_trial, auto_renew, environment, revoked_at_ms,
      signed_date_ms, created_at, updated_at,
    ] = values;
    const key = String(original_transaction_id);
    const existing = this.subscriptions.get(key);
    if (existing && Number(signed_date_ms) < Number(existing.signed_date_ms ?? 0)) return 0;
    const asNumber = (value: unknown) => (value === null || value === undefined ? null : Number(value));
    this.subscriptions.set(key, {
      original_transaction_id: key,
      tenant_id: (tenant_id === null ? null : String(tenant_id)) ?? existing?.tenant_id ?? null,
      product_id: String(product_id),
      status: String(status),
      expires_at_ms: asNumber(expires_at_ms),
      grace_expires_at_ms: asNumber(grace_expires_at_ms),
      is_trial: Number(is_trial),
      auto_renew: Number(auto_renew),
      environment: String(environment),
      revoked_at_ms: asNumber(revoked_at_ms),
      signed_date_ms: Number(signed_date_ms),
      created_at: String(existing?.created_at ?? created_at),
      updated_at: String(updated_at),
    });
    return 1;
  }

  /// Retires a tenant, the way an operator does directly in D1. No production
  /// statement writes `disabled_at`, so this is a seed helper rather than a
  /// SQL handler — teaching the fake a statement the Worker never issues would
  /// be inventing behaviour to test against.
  disableTenant(id: string, at = new Date().toISOString()): void {
    const row = this.tenants.get(id);
    if (row) row.disabled_at = at;
  }

  /// Seeds an entitlement directly, for tests about enforcement rather than
  /// about verification.
  seedSubscription(row: {
    originalTransactionId?: string;
    tenantId?: string | null;
    productId?: string;
    status?: string;
    expiresAtMs?: number | null;
    graceExpiresAtMs?: number | null;
    isTrial?: boolean;
    autoRenew?: boolean;
    environment?: string;
    revokedAtMs?: number | null;
    signedDateMs?: number;
  } = {}): void {
    const id = row.originalTransactionId ?? "original-transaction-1";
    this.subscriptions.set(id, {
      original_transaction_id: id,
      tenant_id: row.tenantId === undefined ? "test-tenant" : row.tenantId,
      product_id: row.productId ?? "com.example.app.pro.monthly",
      status: row.status ?? "active",
      expires_at_ms: row.expiresAtMs === undefined ? Date.now() + 30 * 86400_000 : row.expiresAtMs,
      grace_expires_at_ms: row.graceExpiresAtMs ?? null,
      is_trial: row.isTrial ? 1 : 0,
      auto_renew: row.autoRenew === false ? 0 : 1,
      environment: row.environment ?? "Production",
      revoked_at_ms: row.revokedAtMs ?? null,
      signed_date_ms: row.signedDateMs ?? 1,
      created_at: "2026-01-01T00:00:00.000Z",
      updated_at: "2026-01-01T00:00:00.000Z",
    });
  }

  all(sql: string, values: unknown[]): FakeApiKeyRow[] {
    const normalized = normalizeSql(sql);
    if (normalized.startsWith("SELECT token, last_sent_at, allowance FROM widget_push_cadence")) {
      const wanted = new Set(values.map(String));
      return [...this.widgetPushCadence.values()].filter((row) => wanted.has(String(row.token)));
    }
    if (normalized.startsWith("DELETE FROM activity_history WHERE rowid IN")) {
      const [cutoff, limit] = values.map(Number);
      const doomed = [...this.activityHistory]
        .filter(([, row]) => Number(row.expires_at) < cutoff)
        .slice(0, limit);
      for (const [key] of doomed) this.activityHistory.delete(key);
      return doomed.map((_, index) => ({ rowid: index + 1 })) as unknown as FakeApiKeyRow[];
    }
    if (normalized.startsWith("SELECT activity_instance_id, external_id, kind, title, final_state, final_subtitle, started_at, ended_at FROM activity_history")) {
      const [tenant_id, now] = values;
      return [...this.activityHistory.values()]
        .filter((row) => row.tenant_id === String(tenant_id) && Number(row.expires_at) > Number(now))
        .sort((a, b) => String(b.ended_at).localeCompare(String(a.ended_at)));
    }
    if (normalized.startsWith("SELECT original_transaction_id, tenant_id, product_id, status, expires_at_ms, grace_expires_at_ms, is_trial, auto_renew, environment, revoked_at_ms, signed_date_ms, created_at, updated_at FROM subscriptions WHERE tenant_id = ?")) {
      const [tenant_id] = values.map(String);
      return [...this.subscriptions.values()]
        .filter((row) => row.tenant_id === tenant_id)
        .sort((a, b) => Number(b.expires_at_ms ?? 0) - Number(a.expires_at_ms ?? 0));
    }
    if (normalized.startsWith("SELECT original_transaction_id, tenant_id, product_id, status, expires_at_ms, grace_expires_at_ms, is_trial, auto_renew, environment, revoked_at_ms, signed_date_ms FROM subscriptions WHERE tenant_id = ?")) {
      const [tenant_id, ...environments] = values.map(String);
      return [...this.subscriptions.values()]
        .filter((row) => row.tenant_id === tenant_id
          && environments.some((environment) =>
            environment.toLowerCase() === String(row.environment).toLowerCase()))
        .sort((a, b) => Number(b.expires_at_ms ?? 0) - Number(a.expires_at_ms ?? 0))
        .slice(0, 1);
    }
    if (normalized === "SELECT tenant_id FROM subscriptions WHERE original_transaction_id = ?") {
      const [id] = values.map(String);
      const row = this.subscriptions.get(id);
      return row ? [{ tenant_id: row.tenant_id ?? null }] : [];
    }
    if (normalized === "SELECT api_keys.id, api_keys.tenant_id, tenants.owner_email, api_keys.last_used_at, api_keys.kind, api_keys.session_id, api_keys.device_id, api_keys.expires_at, api_keys.scopes_json, api_keys.renew_seconds, api_keys.resource_kind, api_keys.resource_id FROM api_keys JOIN tenants ON tenants.id = api_keys.tenant_id WHERE api_keys.token_hash = ? AND api_keys.revoked_at IS NULL AND tenants.disabled_at IS NULL") {
      const [token_hash] = values.map(String);
      const row = [...this.apiKeys.values()].find((candidate) => {
        const tenant = this.tenants.get(String(candidate.tenant_id ?? ""));
        return candidate.token_hash === token_hash && !candidate.revoked_at && tenant && !tenant.disabled_at;
      });
      return row
        ? [{
            id: row.id,
            tenant_id: row.tenant_id,
            owner_email: this.tenants.get(String(row.tenant_id ?? ""))?.owner_email || null,
            last_used_at: row.last_used_at,
            kind: row.kind,
            session_id: row.session_id,
            device_id: row.device_id,
            expires_at: row.expires_at,
            scopes_json: row.scopes_json,
            renew_seconds: row.renew_seconds ?? null,
            // Empty string is how this fake spells an absent TEXT column;
            // real D1 hands back NULL, and auth.ts treats both as unbound.
            resource_kind: row.resource_kind || null,
            resource_id: row.resource_id || null,
          }]
        : [];
    }
    if (normalized === "SELECT api_keys.tenant_id, tenants.owner_email, api_keys.kind, api_keys.expires_at, api_keys.scopes_json FROM api_keys JOIN tenants ON tenants.id = api_keys.tenant_id WHERE api_keys.token_hash = ? AND api_keys.revoked_at IS NULL AND tenants.disabled_at IS NULL") {
      const [token_hash] = values.map(String);
      const row = [...this.apiKeys.values()].find((candidate) => {
        const tenant = this.tenants.get(String(candidate.tenant_id ?? ""));
        return candidate.token_hash === token_hash && !candidate.revoked_at && tenant && !tenant.disabled_at;
      });
      return row
        ? [{
            tenant_id: row.tenant_id,
            owner_email: this.tenants.get(String(row.tenant_id ?? ""))?.owner_email || null,
            kind: row.kind,
            expires_at: row.expires_at,
            scopes_json: row.scopes_json,
          }]
        : [];
    }
    if (normalized === "SELECT id, owner_email, created_at, disabled_at FROM tenants ORDER BY created_at DESC, owner_email") {
      return [...this.tenants.values()].sort(by("created_at", "owner_email")).reverse();
    }
    if (normalized === "SELECT id, owner_email, created_at, disabled_at FROM tenants WHERE id = ?") {
      const [id] = values.map(String);
      return pick(this.tenants.get(id), ["id", "owner_email", "created_at", "disabled_at"]);
    }
    if (normalized === "SELECT id, owner_email FROM tenants WHERE lower(owner_email) = ? AND disabled_at IS NULL ORDER BY created_at ASC LIMIT 1") {
      const [owner_email] = values.map(String);
      const row = [...this.tenants.values()]
        .filter((candidate) => candidate.owner_email.toLowerCase() === owner_email && !candidate.disabled_at)
        .sort(by("created_at"))[0];
      return pick(row, ["id", "owner_email"]);
    }
    if (normalized === "SELECT id, tenant_id, token_hash, label, created_at, last_used_at, revoked_at, kind, session_id, device_id, expires_at, scopes_json, renew_seconds, resource_kind, resource_id FROM api_keys ORDER BY created_at DESC") {
      return [...this.apiKeys.values()].sort(by("created_at")).reverse();
    }
    if (normalized === "SELECT id, tenant_id, token_hash, label, created_at, last_used_at, revoked_at, kind, session_id, device_id, expires_at, scopes_json, renew_seconds, resource_kind, resource_id FROM api_keys WHERE tenant_id = ? AND kind = 'guest' AND revoked_at IS NULL AND expires_at > ? ORDER BY created_at DESC") {
      const [tenant_id, now] = values.map(String);
      return [...this.apiKeys.values()]
        .filter((row) => row.tenant_id === tenant_id
          && row.kind === "guest"
          && !row.revoked_at
          && String(row.expires_at) > now)
        .sort(by("created_at"))
        .reverse();
    }
    if (normalized === "SELECT COUNT(*) AS total FROM api_keys WHERE tenant_id = ? AND kind = 'guest' AND revoked_at IS NULL AND expires_at > ?") {
      const [tenant_id, now] = values.map(String);
      const total = [...this.apiKeys.values()].filter((row) => row.tenant_id === tenant_id
        && row.kind === "guest"
        && !row.revoked_at
        && String(row.expires_at) > now).length;
      return [{ total } as unknown as FakeApiKeyRow];
    }
    if (normalized === "SELECT id, tenant_id, token_hash, label, created_at, last_used_at, revoked_at, kind, session_id, device_id, expires_at, scopes_json, renew_seconds, resource_kind, resource_id FROM api_keys WHERE id = ? AND tenant_id = ? AND kind = 'guest'") {
      const [id, tenant_id] = values.map(String);
      const row = [...this.apiKeys.values()].find((candidate) => candidate.id === id
        && candidate.tenant_id === tenant_id
        && candidate.kind === "guest");
      return row ? [row] : [];
    }
    if (normalized === "SELECT id, label, created_at, last_used_at, expires_at, scopes_json FROM api_keys WHERE tenant_id = ? AND purpose = 'connector' AND revoked_at IS NULL AND expires_at > ? ORDER BY created_at DESC") {
      const [tenant_id, now] = values.map(String);
      return [...this.apiKeys.values()]
        .filter((row) => row.tenant_id === tenant_id
          && row.purpose === "connector"
          && !row.revoked_at
          && String(row.expires_at) > now)
        .sort(by("created_at"))
        .reverse();
    }
    if (normalized === "SELECT id, label, created_at, last_used_at, expires_at, scopes_json FROM api_keys WHERE id = ? AND tenant_id = ? AND purpose = 'connector'") {
      const [id, tenant_id] = values.map(String);
      const row = [...this.apiKeys.values()].find((candidate) => candidate.id === id
        && candidate.tenant_id === tenant_id
        && candidate.purpose === "connector");
      return row ? [row] : [];
    }
    if (normalized === "SELECT token_hash FROM api_keys WHERE tenant_id = ? AND session_id = ?") {
      const [tenant_id, session_id] = values.map(String);
      return [...this.apiKeys.values()]
        .filter((row) => row.tenant_id === tenant_id && row.session_id === session_id)
        .map(select("token_hash"));
    }
    if (normalized === "SELECT id, tenant_id, token_hash, session_id, device_id FROM api_keys WHERE id = ?") {
      const [id] = values.map(String);
      const row = [...this.apiKeys.values()].find((candidate) => candidate.id === id);
      return pick(row, ["id", "tenant_id", "token_hash", "session_id", "device_id"]);
    }
    if (normalized === "SELECT apple_sub, tenant_id, email FROM apple_accounts WHERE apple_sub = ?") {
      const [apple_sub] = values.map(String);
      return pick(this.appleAccounts.get(apple_sub), ["apple_sub", "tenant_id", "email"]);
    }
    if (normalized.startsWith("DELETE FROM rate_limit_buckets WHERE rowid IN")) {
      const removed = this.deleteExpiredRateLimitBuckets(values);
      return Array.from({ length: removed }, (_, index) => ({ rowid: index + 1 }));
    }
    if (normalized.startsWith("INSERT INTO widget_push_pending") && normalized.endsWith("RETURNING generation")) {
      return [{ generation: this.upsertWidgetPushPending(values) } as unknown as FakeApiKeyRow];
    }
    if (normalized.startsWith("INSERT INTO rate_limit_buckets") && normalized.endsWith("RETURNING count")) {
      return [{ count: this.upsertRateLimitBucket(values) } as unknown as FakeApiKeyRow];
    }
    if (normalized === "SELECT bucket_key, window_start, count, expires_at FROM rate_limit_buckets WHERE bucket_key = ? AND window_start = ?") {
      const [bucket_key, window_start] = values.map(String);
      return pick(this.rateLimitBuckets.get(`${bucket_key}:${window_start}`), [
        "bucket_key",
        "window_start",
        "count",
        "expires_at",
      ]);
    }
    // The derived-totals read inside incrementRateLimitBuckets. Same range, no
    // ordering, three columns — a separate branch because FakeD1 matches the
    // statement text exactly.
    if (normalized === "SELECT bucket_key, window_start, count FROM rate_limit_buckets WHERE bucket_key >= ? AND bucket_key < ?") {
      const [low, high] = values.map(String);
      return [...this.rateLimitBuckets.values()]
        .filter((row) => row.bucket_key >= low && row.bucket_key < high)
        .map(select("bucket_key", "window_start", "count"));
    }
    // Half-open range over one scope, matching the seek the real query does.
    // Modelled as an actual string comparison rather than a prefix test, so a
    // mistake in the bounds shows up here rather than only against D1.
    if (normalized === "SELECT bucket_key, window_start, count, expires_at FROM rate_limit_buckets WHERE bucket_key >= ? AND bucket_key < ? ORDER BY bucket_key, window_start DESC") {
      const [low, high] = values.map(String);
      return [...this.rateLimitBuckets.values()]
        .filter((row) => row.bucket_key >= low && row.bucket_key < high)
        .sort(by("bucket_key", "window_start"))
        .reverse()
        .map(select("bucket_key", "window_start", "count", "expires_at"));
    }
    if (normalized === "SELECT json FROM cards WHERE tenant_id = ? AND id = ?") {
      const [tenant_id, id] = values.map(String);
      return pick(this.cards.get(`${tenant_id}:${id}`), ["json"]);
    }
    if (normalized === "SELECT json FROM action_payloads WHERE tenant_id = ? AND card_id = ? AND action_id = ?") {
      const [tenant_id, card_id, action_id] = values.map(String);
      return pick(this.actionPayloads.get(`${tenant_id}:${card_id}:${action_id}`), ["json"]);
    }
    if (normalized === "SELECT json FROM webhook_integrations WHERE tenant_id = ?") {
      const [tenant_id] = values.map(String);
      return pick(this.webhookIntegrations.get(tenant_id), ["json"]);
    }
    if (normalized === "SELECT json FROM cards WHERE tenant_id = ? ORDER BY id") {
      const [tenant_id] = values.map(String);
      return byTenant(this.cards, tenant_id).sort(by("id")).map((row) => ({ json: row.json }));
    }
    if (normalized === "SELECT token FROM widget_tokens WHERE tenant_id = ? ORDER BY device_id, widget_kind") {
      const [tenant_id] = values.map(String);
      return byTenant(this.widgetTokens, tenant_id)
        .sort(by("device_id", "widget_kind"))
        .map((row) => ({ token: row.token }));
    }
    if (normalized === "SELECT token FROM widget_tokens WHERE tenant_id = ? AND widget_kind = ? ORDER BY device_id") {
      const [tenant_id, widget_kind] = values.map(String);
      return byTenant(this.widgetTokens, tenant_id)
        .filter((row) => row.widget_kind === widget_kind)
        .sort(by("device_id"))
        .map((row) => ({ token: row.token }));
    }
    if (normalized === "SELECT token, card_ids_json, all_cards FROM widget_tokens WHERE tenant_id = ? ORDER BY device_id, widget_kind") {
      const [tenant_id] = values.map(String);
      return byTenant(this.widgetTokens, tenant_id)
        .sort(by("device_id", "widget_kind"))
        .map(select("token", "card_ids_json", "all_cards"));
    }
    if (normalized === "SELECT tenant_id, generation, queued_at FROM widget_push_pending WHERE tenant_id = ?") {
      const [tenant_id] = values.map(String);
      return pick(this.widgetPushPending.get(tenant_id), ["tenant_id", "generation", "queued_at"]);
    }

    if (normalized === "SELECT instances.json AS json FROM activity_instances AS instances JOIN activity_targets AS targets ON targets.activity_instance_id = instances.id WHERE instances.id = ? AND targets.target_tenant_id = ?") {
      const [id, target_tenant_id] = values.map(String);
      const targeted = [...this.activityTargets.values()].some(
        (target) => target.activity_instance_id === id &&
          target.target_tenant_id === target_tenant_id,
      );
      return targeted ? pick(this.activityInstances.get(id), ["json"]) : [];
    }
    if (normalized === "SELECT json FROM activity_instances WHERE owner_tenant_id = ? AND external_id = ?") {
      const [owner_tenant_id, external_id] = values.map(String);
      const row = [...this.activityInstances.values()].find(
        (candidate) => candidate.owner_tenant_id === owner_tenant_id &&
          candidate.external_id === external_id,
      );
      return pick(row, ["json"]);
    }
    // Mirrors listActivityInstancesForTarget. `owner_tenant_id` rides along on
    // the same row so a caller can tell an owned activity from one shared to
    // this tenant; selecting it here keeps the fake honest about which columns
    // the real statement actually returns.
    if (normalized === "SELECT instances.json AS json, instances.owner_tenant_id AS owner_tenant_id FROM activity_instances AS instances JOIN activity_targets AS targets ON targets.activity_instance_id = instances.id WHERE targets.target_tenant_id = ? ORDER BY instances.updated_at DESC, instances.id") {
      const [target_tenant_id] = values.map(String);
      return [...this.activityTargets.values()]
        .filter((target) => target.target_tenant_id === target_tenant_id)
        .map((target) => this.activityInstances.get(target.activity_instance_id))
        .filter((row): row is FakeRow => Boolean(row))
        .sort((a, b) => b.updated_at.localeCompare(a.updated_at) || a.id.localeCompare(b.id))
        .map(select("json", "owner_tenant_id"));
    }
    if (normalized === "SELECT instances.json AS json FROM activity_instances AS instances JOIN activity_targets AS targets ON targets.activity_instance_id = instances.id WHERE targets.target_tenant_id = ? AND NOT EXISTS ( SELECT 1 FROM activity_deliveries AS deliveries WHERE deliveries.activity_instance_id = instances.id AND deliveries.target_tenant_id = targets.target_tenant_id ) ORDER BY instances.updated_at DESC, instances.id") {
      const [target_tenant_id] = values.map(String);
      return [...this.activityTargets.values()]
        .filter((target) => target.target_tenant_id === target_tenant_id)
        .filter((target) => ![...this.activityDeliveries.values()].some(
          (delivery) => delivery.activity_instance_id === target.activity_instance_id &&
            delivery.target_tenant_id === target.target_tenant_id,
        ))
        .map((target) => this.activityInstances.get(target.activity_instance_id))
        .filter((row): row is FakeRow => Boolean(row))
        .sort((a, b) => b.updated_at.localeCompare(a.updated_at) || a.id.localeCompare(b.id))
        .map(select("json"));
    }
    if (normalized === "SELECT json FROM activity_instances WHERE owner_tenant_id = ? AND kind = ? ORDER BY updated_at DESC, id") {
      const [owner_tenant_id, kind] = values.map(String);
      return [...this.activityInstances.values()]
        .filter((row) => row.owner_tenant_id === owner_tenant_id && row.kind === kind)
        .sort((a, b) => b.updated_at.localeCompare(a.updated_at) || a.id.localeCompare(b.id))
        .map(select("json"));
    }
    if (normalized === "SELECT activity_instance_id, owner_tenant_id, target_tenant_id, share_id FROM activity_targets WHERE activity_instance_id = ? AND target_tenant_id = ?") {
      const [activity_instance_id, target_tenant_id] = values.map(String);
      return pick(
        this.activityTargets.get(`${activity_instance_id}:${target_tenant_id}`),
        ["activity_instance_id", "owner_tenant_id", "target_tenant_id", "share_id"],
      );
    }
    if (normalized === "SELECT instances.json AS json FROM activity_instances AS instances JOIN activity_targets AS targets ON targets.activity_instance_id = instances.id WHERE targets.target_tenant_id = ? AND instances.external_id = ? AND instances.kind = ? ORDER BY instances.id") {
      const [target_tenant_id, external_id, kind] = values.map(String);
      return [...this.activityTargets.values()]
        .filter((target) => target.target_tenant_id === target_tenant_id)
        .map((target) => this.activityInstances.get(target.activity_instance_id))
        .filter((row): row is FakeRow =>
          row !== undefined && row.external_id === external_id && row.kind === kind)
        .sort(by("id"))
        .map(select("json"));
    }
    if (normalized === "SELECT activity_instance_id, owner_tenant_id, target_tenant_id, share_id, api_key_hash, json FROM activity_deliveries WHERE activity_instance_id = ? ORDER BY target_tenant_id, device_id") {
      const [activity_instance_id] = values.map(String);
      return [...this.activityDeliveries.values()]
        .filter((row) => row.activity_instance_id === activity_instance_id)
        .sort(by("target_tenant_id", "device_id"))
        .map(select("activity_instance_id", "owner_tenant_id", "target_tenant_id", "share_id", "api_key_hash", "json"));
    }
    if (normalized === "SELECT activity_instance_id, owner_tenant_id, target_tenant_id, share_id, api_key_hash, json FROM activity_deliveries WHERE share_id = ? ORDER BY activity_instance_id, device_id") {
      const [share_id] = values.map(String);
      return [...this.activityDeliveries.values()]
        .filter((row) => row.share_id === share_id)
        .sort(by("activity_instance_id", "device_id"))
        .map(select("activity_instance_id", "owner_tenant_id", "target_tenant_id", "share_id", "api_key_hash", "json"));
    }
    if (normalized === "SELECT json FROM activities WHERE tenant_id = ? AND external_id = ? ORDER BY device_id") {
      const [tenant_id, external_id] = values.map(String);
      return byTenant(this.activities, tenant_id)
        .filter((row) => row.external_id === external_id)
        .sort(by("device_id"))
        .map(select("json"));
    }
    if (normalized === "SELECT external_id, json FROM activities WHERE tenant_id = ? ORDER BY external_id, device_id") {
      const [tenant_id] = values.map(String);
      return byTenant(this.activities, tenant_id)
        .sort(by("external_id", "device_id"))
        .map(select("external_id", "json"));
    }
    if (normalized === "SELECT json FROM activities WHERE tenant_id = ? AND external_id = ? AND device_id = ?") {
      const [tenant_id, external_id, device_id] = values.map(String);
      return pick(this.activities.get(`${tenant_id}:${external_id}:${device_id}`), ["json"]);
    }
    if (normalized === "SELECT json FROM pending_activities WHERE tenant_id = ? AND external_id = ?") {
      const [tenant_id, external_id] = values.map(String);
      return pick(this.pendingActivities.get(`${tenant_id}:${external_id}`), ["json"]);
    }
    if (normalized === "SELECT token FROM start_tokens WHERE tenant_id = ? AND attributes_type = ? ORDER BY device_id") {
      const [tenant_id, attributes_type] = values.map(String);
      return byTenant(this.startTokens, tenant_id)
        .filter((row) => row.attributes_type === attributes_type)
        .sort(by("device_id"))
        .map((row) => ({ token: row.token }));
    }
    if (normalized === "SELECT token FROM start_tokens WHERE tenant_id = ? AND device_id = ? AND attributes_type = ?") {
      const [tenant_id, device_id, attributes_type] = values.map(String);
      return pick(
        this.startTokens.get(`${tenant_id}:${device_id}:${attributes_type}`),
        ["token"],
      );
    }
    if (normalized === "SELECT api_key_hash, id, json FROM cards ORDER BY api_key_hash, id") {
      return [...this.cards.values()].sort(by("api_key_hash", "id")).map(select("api_key_hash", "id", "json"));
    }
    if (normalized === "SELECT api_key_hash, id, json FROM cards WHERE tenant_id = ? ORDER BY api_key_hash, id") {
      const [tenant_id] = values.map(String);
      return byTenant(this.cards, tenant_id)
        .sort(by("api_key_hash", "id"))
        .map(select("api_key_hash", "id", "json"));
    }
    if (normalized === "SELECT api_key_hash, device_id, json FROM devices ORDER BY api_key_hash, device_id") {
      return [...this.devices.values()]
        .sort(by("api_key_hash", "device_id"))
        .map(select("api_key_hash", "device_id", "json"));
    }
    if (normalized === "SELECT api_key_hash, device_id, json FROM devices WHERE tenant_id = ? ORDER BY api_key_hash, device_id") {
      const [tenant_id] = values.map(String);
      return byTenant(this.devices, tenant_id)
        .sort(by("api_key_hash", "device_id"))
        .map(select("api_key_hash", "device_id", "json"));
    }
    if (normalized === "SELECT api_key_hash, device_id, widget_kind, token FROM widget_tokens ORDER BY api_key_hash, device_id, widget_kind") {
      return [...this.widgetTokens.values()]
        .sort(by("api_key_hash", "device_id", "widget_kind"))
        .map(select("api_key_hash", "device_id", "widget_kind", "token"));
    }
    if (normalized === "SELECT api_key_hash, device_id, widget_kind, token FROM widget_tokens WHERE tenant_id = ? ORDER BY api_key_hash, device_id, widget_kind") {
      const [tenant_id] = values.map(String);
      return byTenant(this.widgetTokens, tenant_id)
        .sort(by("api_key_hash", "device_id", "widget_kind"))
        .map(select("api_key_hash", "device_id", "widget_kind", "token"));
    }
    if (normalized === "SELECT tokens.api_key_hash, tokens.device_id, tokens.widget_kind, tokens.token, tokens.updated_at, tokens.app_version, tokens.platform, diagnostics.attempted_at, diagnostics.status, diagnostics.reason, diagnostics.apns_id, diagnostics.attempts FROM widget_tokens AS tokens LEFT JOIN widget_push_delivery_diagnostics AS diagnostics ON diagnostics.token = tokens.token WHERE tokens.tenant_id = ? ORDER BY tokens.api_key_hash, tokens.device_id, tokens.widget_kind") {
      const [tenant_id] = values.map(String);
      return byTenant(this.widgetTokens, tenant_id)
        .sort(by("api_key_hash", "device_id", "widget_kind"))
        .map((row) => ({
          ...select(
            "api_key_hash",
            "device_id",
            "widget_kind",
            "token",
            "updated_at",
            "app_version",
            "platform",
          )(row),
          ...(this.widgetPushDeliveryDiagnostics.get(String(row.token)) ?? {
            attempted_at: null,
            status: null,
            reason: null,
            apns_id: null,
            attempts: null,
          }),
        }));
    }
    if (normalized === "SELECT DISTINCT diagnostics.token, diagnostics.attempted_at, diagnostics.status, diagnostics.reason, diagnostics.apns_id, diagnostics.attempts FROM widget_push_delivery_diagnostics AS diagnostics JOIN widget_tokens AS tokens ON tokens.token = diagnostics.token WHERE tokens.tenant_id = ? ORDER BY diagnostics.attempted_at DESC") {
      const [tenant_id] = values.map(String);
      const tokens = new Set(byTenant(this.widgetTokens, tenant_id).map((row) => String(row.token)));
      return [...this.widgetPushDeliveryDiagnostics.values()]
        .filter((row) => tokens.has(String(row.token)))
        .sort((a, b) => String(b.attempted_at).localeCompare(String(a.attempted_at)))
        .map(select("token", "attempted_at", "status", "reason", "apns_id", "attempts"));
    }
    if (normalized === "SELECT api_key_hash, device_id, widget_kind, token, updated_at, app_version, platform FROM widget_tokens ORDER BY api_key_hash, device_id, widget_kind") {
      return [...this.widgetTokens.values()]
        .sort(by("api_key_hash", "device_id", "widget_kind"))
        .map(select(
          "api_key_hash",
          "device_id",
          "widget_kind",
          "token",
          "updated_at",
          "app_version",
          "platform",
        ));
    }
    if (normalized === "SELECT deliveries.api_key_hash AS api_key_hash, deliveries.activity_instance_id AS activity_instance_id, instances.external_id AS external_id, instances.updated_at AS instance_updated_at, deliveries.json AS json FROM activity_deliveries AS deliveries JOIN activity_instances AS instances ON instances.id = deliveries.activity_instance_id WHERE deliveries.target_tenant_id = ? ORDER BY deliveries.api_key_hash, instances.external_id, deliveries.device_id") {
      const [target_tenant_id] = values.map(String);
      return [...this.activityDeliveries.values()]
        .filter((delivery) => delivery.target_tenant_id === target_tenant_id)
        .map((delivery) => ({ delivery, instance: this.activityInstances.get(delivery.activity_instance_id) }))
        .filter((entry) => Boolean(entry.instance))
        .sort((a, b) =>
          a.delivery.api_key_hash.localeCompare(b.delivery.api_key_hash) ||
          (a.instance?.external_id ?? "").localeCompare(b.instance?.external_id ?? "") ||
          a.delivery.device_id.localeCompare(b.delivery.device_id))
        .map(({ delivery, instance }) => ({
          api_key_hash: delivery.api_key_hash,
          activity_instance_id: delivery.activity_instance_id,
          external_id: instance?.external_id ?? "",
          instance_updated_at: instance?.updated_at ?? "",
          json: delivery.json,
        }));
    }
    if (normalized === "SELECT instances.api_key_hash AS api_key_hash, instances.id AS activity_instance_id, instances.json AS json FROM activity_instances AS instances JOIN activity_targets AS targets ON targets.activity_instance_id = instances.id WHERE targets.target_tenant_id = ? AND NOT EXISTS ( SELECT 1 FROM activity_deliveries AS deliveries WHERE deliveries.activity_instance_id = instances.id AND deliveries.target_tenant_id = targets.target_tenant_id ) ORDER BY instances.api_key_hash, instances.external_id") {
      const [target_tenant_id] = values.map(String);
      return [...this.activityTargets.values()]
        .filter((target) => target.target_tenant_id === target_tenant_id)
        .filter((target) => ![...this.activityDeliveries.values()].some(
          (delivery) => delivery.activity_instance_id === target.activity_instance_id &&
            delivery.target_tenant_id === target.target_tenant_id,
        ))
        .map((target) => this.activityInstances.get(target.activity_instance_id))
        .filter((row): row is FakeRow => Boolean(row))
        .sort(by("api_key_hash", "external_id"))
        .map((row) => ({
          api_key_hash: row.api_key_hash,
          activity_instance_id: row.id,
          json: row.json,
        }));
    }
    if (normalized === "SELECT deliveries.api_key_hash AS api_key_hash, deliveries.activity_instance_id AS activity_instance_id, deliveries.json AS json FROM activity_deliveries AS deliveries ORDER BY deliveries.api_key_hash, deliveries.activity_instance_id, deliveries.device_id") {
      return [...this.activityDeliveries.values()]
        .sort(by("api_key_hash", "activity_instance_id", "device_id"))
        .map(select("api_key_hash", "activity_instance_id", "json"));
    }
    if (normalized === "SELECT instances.api_key_hash AS api_key_hash, instances.id AS activity_instance_id, instances.json AS json FROM activity_instances AS instances ORDER BY instances.api_key_hash, instances.external_id") {
      return [...this.activityInstances.values()]
        .sort(by("api_key_hash", "external_id"))
        .map((row) => ({
          api_key_hash: row.api_key_hash,
          activity_instance_id: row.id,
          json: row.json,
        }));
    }
    if (normalized === "SELECT api_key_hash, external_id, json FROM activities ORDER BY api_key_hash, external_id") {
      return [...this.activities.values()]
        .sort(by("api_key_hash", "external_id"))
        .map(select("api_key_hash", "external_id", "json"));
    }
    if (normalized === "SELECT api_key_hash, external_id, json FROM activities WHERE tenant_id = ? ORDER BY api_key_hash, external_id") {
      const [tenant_id] = values.map(String);
      return byTenant(this.activities, tenant_id)
        .sort(by("api_key_hash", "external_id"))
        .map(select("api_key_hash", "external_id", "json"));
    }
    if (normalized === "SELECT api_key_hash, external_id, json FROM pending_activities ORDER BY api_key_hash, external_id") {
      return [...this.pendingActivities.values()]
        .sort(by("api_key_hash", "external_id"))
        .map(select("api_key_hash", "external_id", "json"));
    }
    if (normalized === "SELECT api_key_hash, external_id, json FROM pending_activities WHERE tenant_id = ? ORDER BY api_key_hash, external_id") {
      const [tenant_id] = values.map(String);
      return byTenant(this.pendingActivities, tenant_id)
        .sort(by("api_key_hash", "external_id"))
        .map(select("api_key_hash", "external_id", "json"));
    }
    if (normalized === "SELECT api_key_hash, device_id, attributes_type, token FROM start_tokens ORDER BY api_key_hash, device_id, attributes_type") {
      return [...this.startTokens.values()]
        .sort(by("api_key_hash", "device_id", "attributes_type"))
        .map(select("api_key_hash", "device_id", "attributes_type", "token"));
    }
    if (normalized === "SELECT api_key_hash, device_id, attributes_type, token FROM start_tokens WHERE tenant_id = ? ORDER BY api_key_hash, device_id, attributes_type") {
      const [tenant_id] = values.map(String);
      return byTenant(this.startTokens, tenant_id)
        .sort(by("api_key_hash", "device_id", "attributes_type"))
        .map(select("api_key_hash", "device_id", "attributes_type", "token"));
    }
    if (normalized === "SELECT json FROM pending_activities WHERE tenant_id = ? ORDER BY external_id") {
      const [tenant_id] = values.map(String);
      return byTenant(this.pendingActivities, tenant_id)
        .sort(by("external_id"))
        .map((row) => ({ json: row.json }));
    }
    if (normalized === "SELECT owner_email FROM tenants WHERE id = ?") {
      const [id] = values.map(String);
      const row = this.tenants.get(id);
      return row ? [{ owner_email: row.owner_email ?? "" }] : [];
    }
    if (normalized === "SELECT id FROM cards WHERE tenant_id = ? AND id = ?") {
      const [tenant_id, id] = values.map(String);
      const row = this.cards.get(`${tenant_id}:${id}`);
      return row ? [{ id: row.id }] : [];
    }
    if (
      normalized.startsWith(
        "SELECT id, owner_tenant_id, recipient_tenant_id, recipient_email, resource_kind, resource_id, status, created_at, accepted_at, revoked_at FROM shares WHERE id = ?",
      )
    ) {
      const [id] = values.map(String);
      const row = this.shares.get(id);
      return row ? [shareSelect(row)] : [];
    }
    if (
      normalized.startsWith(
        "SELECT id, status FROM shares WHERE owner_tenant_id = ? AND lower(recipient_email) = ? AND resource_kind = ? AND resource_id = ? AND status IN",
      )
    ) {
      const [owner_tenant_id, recipient_email, resource_kind, resource_id] = values.map(String);
      const row = [...this.shares.values()].find((candidate) => {
        return (
          candidate.owner_tenant_id === owner_tenant_id &&
          candidate.recipient_email.toLowerCase() === recipient_email &&
          candidate.resource_kind === resource_kind &&
          candidate.resource_id === resource_id &&
          (candidate.status === "pending" || candidate.status === "accepted")
        );
      });
      return row ? [{ id: row.id, status: row.status }] : [];
    }
    if (
      normalized.startsWith(
        "SELECT id, owner_tenant_id, recipient_tenant_id, recipient_email, resource_kind, resource_id, status, created_at, accepted_at, revoked_at FROM shares WHERE owner_tenant_id = ? ORDER BY created_at DESC",
      )
    ) {
      const [owner_tenant_id] = values.map(String);
      return [...this.shares.values()]
        .filter((row) => row.owner_tenant_id === owner_tenant_id)
        .sort(by("created_at"))
        .reverse()
        .map(shareSelect);
    }
    if (
      normalized.startsWith(
        "SELECT shares.id AS id, shares.owner_tenant_id AS owner_tenant_id, shares.recipient_tenant_id AS recipient_tenant_id, shares.recipient_email AS recipient_email, shares.resource_kind AS resource_kind, shares.resource_id AS resource_id, shares.status AS status, shares.created_at AS created_at, shares.accepted_at AS accepted_at, shares.revoked_at AS revoked_at, tenants.owner_email AS owner_email FROM shares LEFT JOIN tenants ON tenants.id = shares.owner_tenant_id WHERE (shares.recipient_tenant_id = ? OR lower(shares.recipient_email) = ?)",
      )
    ) {
      const [recipient_tenant_id, recipient_email] = values.map(String);
      return [...this.shares.values()]
        .filter(
          (row) =>
            (row.recipient_tenant_id === recipient_tenant_id ||
              row.recipient_email.toLowerCase() === recipient_email) &&
            (row.status === "pending" || row.status === "accepted"),
        )
        .sort(by("created_at"))
        .reverse()
        .map((row) => ({
          ...shareSelect(row),
          owner_email: this.tenants.get(row.owner_tenant_id)?.owner_email ?? "",
        }));
    }
    if (
      normalized.startsWith(
        "SELECT id, owner_tenant_id, recipient_tenant_id, recipient_email, resource_kind, resource_id, status, created_at, accepted_at, revoked_at FROM shares WHERE owner_tenant_id = ? AND resource_kind = ? AND resource_id = ? AND status = 'accepted' AND recipient_tenant_id IS NOT NULL",
      )
    ) {
      const [owner_tenant_id, resource_kind, resource_id] = values.map(String);
      return [...this.shares.values()]
        .filter(
          (row) =>
            row.owner_tenant_id === owner_tenant_id &&
            row.resource_kind === resource_kind &&
            row.resource_id === resource_id &&
            row.status === "accepted" &&
            row.recipient_tenant_id,
        )
        .map(shareSelect);
    }
    if (
      normalized.startsWith(
        "SELECT shares.id AS id, shares.owner_tenant_id AS owner_tenant_id, shares.recipient_tenant_id AS recipient_tenant_id, shares.recipient_email AS recipient_email, shares.resource_kind AS resource_kind, shares.resource_id AS resource_id, shares.status AS status, shares.created_at AS created_at, shares.accepted_at AS accepted_at, shares.revoked_at AS revoked_at, tenants.owner_email AS owner_email FROM shares JOIN tenants ON tenants.id = shares.owner_tenant_id WHERE shares.recipient_tenant_id = ? AND shares.resource_kind = ? AND shares.status = 'accepted'",
      )
    ) {
      const [recipient_tenant_id, resource_kind] = values.map(String);
      return [...this.shares.values()]
        .filter(
          (row) =>
            row.recipient_tenant_id === recipient_tenant_id &&
            row.resource_kind === resource_kind &&
            row.status === "accepted",
        )
        .map((row) => ({
          ...shareSelect(row),
          owner_email: this.tenants.get(row.owner_tenant_id)?.owner_email ?? "",
        }));
    }
    throw new Error(`Unhandled FakeD1 all SQL: ${normalized}`);
  }
}

export class FakeRateLimit {
  readonly calls: string[] = [];
  success = true;
  error?: Error;

  async limit({ key }: RateLimitOptions): Promise<RateLimitOutcome> {
    this.calls.push(key);
    if (this.error) throw this.error;
    return { success: this.success };
  }
}

export function testApiKey(label = "test-key"): string {
  // A real minted token (including a zwg_ guest link) passes through unchanged.
  if (/^(?:zw_[A-Za-z0-9_-]{43}|zwa_[A-Za-z0-9_-]{43}|zwg_[A-Za-z0-9_-]{43})$/.test(label)) return label;
  const safeLabel = label.replace(/[^A-Za-z0-9_-]/g, "_");
  return `zw_${`${safeLabel}_${"x".repeat(43)}`.slice(0, 43)}`;
}

export const TEST_API_KEY = testApiKey();

function shareSelect(row: FakeRow): FakeRow {
  return {
    id: row.id,
    owner_tenant_id: row.owner_tenant_id,
    recipient_tenant_id: row.recipient_tenant_id || "",
    recipient_email: row.recipient_email,
    resource_kind: row.resource_kind,
    resource_id: row.resource_id,
    status: row.status,
    created_at: row.created_at,
    accepted_at: row.accepted_at || "",
    revoked_at: row.revoked_at || "",
  };
}

function normalizeSql(sql: string): string {
  return sql.replace(/\s+/g, " ").trim();
}

function byTenant(rows: Map<string, FakeRow>, tenantId: string): FakeApiKeyRow[] {
  return [...rows.values()].filter((row) => row.tenant_id === tenantId);
}

function by(...fields: string[]): (a: FakeApiKeyRow, b: FakeApiKeyRow) => number {
  return (a, b) => {
    for (const field of fields) {
      const result = String(a[field] ?? "").localeCompare(String(b[field] ?? ""));
      if (result !== 0) return result;
    }
    return 0;
  };
}

function select(...fields: string[]): (row: FakeApiKeyRow) => FakeApiKeyRow {
  return (row) => Object.fromEntries(fields.map((field) => [field, row[field]]));
}

function pick(row: FakeApiKeyRow | undefined, fields: string[]): FakeApiKeyRow[] {
  return row ? [select(...fields)(row)] : [];
}

export function makeEnv(overrides: Partial<Env> = {}): Env {
  const db = new FakeD1();
  db.seedApiKeyHash("f9fc6804ffda6c9ce8014450b5951b83a54158dbf19e6dd654fb8188fdc9bfe8");
  return {
    ZW_DB: db as unknown as D1Database,
    AUTH_SOURCE_LIMITER: new FakeRateLimit() as unknown as RateLimit,
    AUTH_TOKEN_LIMITER: new FakeRateLimit() as unknown as RateLimit,
    API_KEYS: "test-key",
    APNS_TEAM_ID: undefined,
    APNS_KEY_ID: undefined,
    APNS_PRIVATE_KEY: undefined,
    APNS_BUNDLE_ID: "com.example.zerozerowidget",
    APNS_ENV: "sandbox",
    ...overrides,
  };
}

export async function seedApiKey(
  env: Env,
  rawToken: string,
  tenantId: string,
  kind: "publisher" | "app" = "publisher",
  sessionId = "",
  deviceId = "",
  expiresAt = "2099-01-01T00:00:00.000Z",
  scopes?: readonly ApiScope[],
  renewSeconds: number | null = DEFAULT_TOKEN_LIFETIME_SECONDS,
): Promise<void> {
  (env.ZW_DB as unknown as FakeD1).seedApiKeyHash(
    await sha256Hex(testApiKey(rawToken)),
    tenantId,
    "test key",
    kind,
    sessionId,
    deviceId,
    expiresAt,
    scopes,
    renewSeconds,
  );
}

export function authedRequest(url: string, init: RequestInit = {}, apiKey = TEST_API_KEY): Request {
  const headers = new Headers(init.headers);
  headers.set("authorization", `Bearer ${testApiKey(apiKey)}`);
  if (init.body && !headers.has("content-type")) {
    headers.set("content-type", "application/json");
  }
  return new Request(url, { ...init, headers });
}

/// A signed Apple id_token plus the JWK to serve as Apple's JWKS, so a test can
/// drive the real callback without reaching appleid.apple.com.
export async function makeAppleIdToken(input: {
  aud: string;
  email: string;
  emailVerified: boolean | string;
  nonce: string;
  sub?: string;
}): Promise<{ token: string; jwk: JsonWebKey }> {
  const pair = (await crypto.subtle.generateKey(
    {
      name: "RSASSA-PKCS1-v1_5",
      modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]),
      hash: "SHA-256",
    },
    true,
    ["sign", "verify"],
  )) as CryptoKeyPair;
  const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey & {
    kid?: string;
    alg?: string;
    use?: string;
  };
  jwk.kid = "admin-test-kid";
  jwk.alg = "RS256";
  jwk.use = "sig";

  const now = Math.floor(Date.now() / 1000);
  const header = b64urlJson({ alg: "RS256", kid: jwk.kid });
  const payload = b64urlJson({
    iss: "https://appleid.apple.com",
    aud: input.aud,
    exp: now + 300,
    iat: now,
    sub: input.sub ?? "admin-apple-user",
    nonce: input.nonce,
    email: input.email,
    email_verified: input.emailVerified,
  });
  const data = new TextEncoder().encode(`${header}.${payload}`);
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", pair.privateKey, data);
  return { token: `${header}.${payload}.${b64urlBytes(new Uint8Array(signature))}`, jwk };
}

function b64urlJson(value: unknown): string {
  return b64urlBytes(new TextEncoder().encode(JSON.stringify(value)));
}

function b64urlBytes(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}
