import { sha256Hex } from "../src/auth";
import type { Env } from "../src/types";

type FakeRow = Record<string, string>;

class FakeD1Statement {
  constructor(
    private readonly owner: FakeD1,
    private readonly sql: string,
    private readonly values: unknown[] = [],
  ) {}

  bind(...values: unknown[]): FakeD1Statement {
    return new FakeD1Statement(this.owner, this.sql, values);
  }

  async run(): Promise<D1Result> {
    const changes = this.owner.run(this.sql, this.values);
    return { success: true, meta: { changes } } as D1Result;
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
  private apiKeys = new Map<string, FakeRow>();
  private cards = new Map<string, FakeRow>();
  private devices = new Map<string, FakeRow>();
  private widgetTokens = new Map<string, FakeRow>();
  private activities = new Map<string, FakeRow>();
  private pendingActivities = new Map<string, FakeRow>();
  private startTokens = new Map<string, FakeRow>();
  private appleAccounts = new Map<string, FakeRow>();
  private webhookIntegrations = new Map<string, FakeRow>();
  private shares = new Map<string, FakeRow>();
  private rateLimitBuckets = new Map<string, FakeRow>();

  prepare(sql: string): D1PreparedStatement {
    return new FakeD1Statement(this, sql) as unknown as D1PreparedStatement;
  }

  seedApiKeyHash(rawTokenHash: string, tenantId = "test-tenant", label = "test key"): void {
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
    });
  }

  run(sql: string, values: unknown[]): number {
    const normalized = normalizeSql(sql);
    if (normalized.startsWith("INSERT OR IGNORE INTO tenants")) {
      const [id, name, owner_email, created_at] = values.map(String);
      if (this.tenants.has(id)) return 0;
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
      const [id, tenant_id, token_hash, label, created_at] = values.map(String);
      this.apiKeys.set(id, {
        id,
        tenant_id,
        token_hash,
        label,
        created_at,
        last_used_at: "",
        revoked_at: "",
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
      const row = this.apiKeys.get(id);
      if (!row || row.revoked_at) return 0;
      row.revoked_at = revoked_at;
      return 1;
    }
    if (normalized.startsWith("UPDATE api_keys SET last_used_at = ? WHERE id = ? AND revoked_at IS NULL")) {
      const [last_used_at, id] = values.map(String);
      const row = this.apiKeys.get(id);
      if (!row || row.revoked_at) return 0;
      row.last_used_at = last_used_at;
      return 1;
    }
    if (normalized.startsWith("INSERT OR REPLACE INTO cards")) {
      const [tenant_id, api_key_hash, id, json, updated_at] = values.map(String);
      this.cards.set(`${tenant_id}:${id}`, { tenant_id, api_key_hash, id, json, updated_at });
      return 1;
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
      const [tenant_id, api_key_hash, device_id, widget_kind, token, updated_at] =
        values.map(String);
      this.widgetTokens.set(`${tenant_id}:${device_id}:${widget_kind}`, {
        tenant_id,
        api_key_hash,
        device_id,
        widget_kind,
        token,
        updated_at,
      });
      return 1;
    }
    if (normalized.startsWith("INSERT OR REPLACE INTO activities")) {
      const [tenant_id, api_key_hash, external_id, json, updated_at] = values.map(String);
      this.activities.set(`${tenant_id}:${external_id}`, {
        tenant_id,
        api_key_hash,
        external_id,
        json,
        updated_at,
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
    if (normalized.startsWith("DELETE FROM webhook_integrations")) {
      const [tenant_id] = values.map(String);
      this.webhookIntegrations.delete(tenant_id);
      return 1;
    }
    if (normalized.startsWith("DELETE FROM activities")) {
      const [tenant_id, external_id] = values.map(String);
      this.activities.delete(`${tenant_id}:${external_id}`);
      return 1;
    }
    if (normalized.startsWith("DELETE FROM pending_activities")) {
      const [tenant_id, external_id] = values.map(String);
      this.pendingActivities.delete(`${tenant_id}:${external_id}`);
      return 1;
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
    if (normalized.startsWith("DELETE FROM rate_limit_buckets WHERE expires_at < ?")) {
      const [now] = values.map(Number);
      let count = 0;
      for (const [key, row] of this.rateLimitBuckets.entries()) {
        if (Number(row.expires_at) < now) {
          this.rateLimitBuckets.delete(key);
          count++;
        }
      }
      return count;
    }
    if (normalized.startsWith("INSERT INTO rate_limit_buckets")) {
      const [bucket_key, window_start, expires_at] = [String(values[0]), String(values[1]), String(values[2])];
      const key = `${bucket_key}:${window_start}`;
      const existing = this.rateLimitBuckets.get(key);
      this.rateLimitBuckets.set(key, {
        bucket_key,
        window_start,
        count: String(Number(existing?.count ?? 0) + 1),
        expires_at,
      });
      return 1;
    }
    throw new Error(`Unhandled FakeD1 run SQL: ${normalized}`);
  }

  all(sql: string, values: unknown[]): FakeRow[] {
    const normalized = normalizeSql(sql);
    if (normalized === "SELECT api_keys.id, api_keys.tenant_id, api_keys.last_used_at FROM api_keys JOIN tenants ON tenants.id = api_keys.tenant_id WHERE api_keys.token_hash = ? AND api_keys.revoked_at IS NULL AND tenants.disabled_at IS NULL") {
      const [token_hash] = values.map(String);
      const row = [...this.apiKeys.values()].find((candidate) => {
        const tenant = this.tenants.get(candidate.tenant_id);
        return candidate.token_hash === token_hash && !candidate.revoked_at && tenant && !tenant.disabled_at;
      });
      return row
        ? [{ id: row.id, tenant_id: row.tenant_id, last_used_at: row.last_used_at }]
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
    if (normalized === "SELECT id, tenant_id, token_hash, label, created_at, last_used_at, revoked_at FROM api_keys ORDER BY created_at DESC") {
      return [...this.apiKeys.values()].sort(by("created_at")).reverse();
    }
    if (normalized === "SELECT apple_sub, tenant_id, email FROM apple_accounts WHERE apple_sub = ?") {
      const [apple_sub] = values.map(String);
      return pick(this.appleAccounts.get(apple_sub), ["apple_sub", "tenant_id", "email"]);
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
    if (normalized === "SELECT bucket_key, window_start, count, expires_at FROM rate_limit_buckets WHERE bucket_key LIKE ? ORDER BY bucket_key, window_start DESC") {
      const [pattern] = values.map(String);
      const needle = pattern.replace(/^%|%$/g, "");
      return [...this.rateLimitBuckets.values()]
        .filter((row) => row.bucket_key.includes(needle))
        .sort(by("bucket_key", "window_start"))
        .reverse()
        .map(select("bucket_key", "window_start", "count", "expires_at"));
    }
    if (normalized === "SELECT json FROM cards WHERE tenant_id = ? AND id = ?") {
      const [tenant_id, id] = values.map(String);
      return pick(this.cards.get(`${tenant_id}:${id}`), ["json"]);
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
    if (normalized === "SELECT json FROM activities WHERE tenant_id = ? AND external_id = ?") {
      const [tenant_id, external_id] = values.map(String);
      return pick(this.activities.get(`${tenant_id}:${external_id}`), ["json"]);
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

function byTenant(rows: Map<string, FakeRow>, tenantId: string): FakeRow[] {
  return [...rows.values()].filter((row) => row.tenant_id === tenantId);
}

function by(...fields: string[]): (a: FakeRow, b: FakeRow) => number {
  return (a, b) => {
    for (const field of fields) {
      const result = a[field].localeCompare(b[field]);
      if (result !== 0) return result;
    }
    return 0;
  };
}

function select(...fields: string[]): (row: FakeRow) => FakeRow {
  return (row) => Object.fromEntries(fields.map((field) => [field, row[field]]));
}

function pick(row: FakeRow | undefined, fields: string[]): FakeRow[] {
  return row ? [select(...fields)(row)] : [];
}

export function makeEnv(overrides: Partial<Env> = {}): Env {
  const db = new FakeD1();
  db.seedApiKeyHash("62af8704764faf8ea82fc61ce9c4c3908b6cb97d463a634e9e587d7c885db0ef");
  return {
    ZW_DB: db as unknown as D1Database,
    API_KEYS: "test-key",
    APNS_TEAM_ID: undefined,
    APNS_KEY_ID: undefined,
    APNS_PRIVATE_KEY: undefined,
    APNS_BUNDLE_ID: "com.example.zerozerowidget",
    APNS_ENV: "sandbox",
    ...overrides,
  };
}

export async function seedApiKey(env: Env, rawToken: string, tenantId: string): Promise<void> {
  (env.ZW_DB as unknown as FakeD1).seedApiKeyHash(await sha256Hex(rawToken), tenantId);
}

export function authedRequest(url: string, init: RequestInit = {}, apiKey = "test-key"): Request {
  const headers = new Headers(init.headers);
  headers.set("authorization", `Bearer ${apiKey}`);
  if (init.body && !headers.has("content-type")) {
    headers.set("content-type", "application/json");
  }
  return new Request(url, { ...init, headers });
}
