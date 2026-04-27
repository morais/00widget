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

  prepare(sql: string): D1PreparedStatement {
    return new FakeD1Statement(this, sql) as unknown as D1PreparedStatement;
  }

  seedApiKeyHash(rawTokenHash: string, tenantId = "test-tenant", label = "test key"): void {
    const now = "2026-01-01T00:00:00.000Z";
    if (!this.tenants.has(tenantId)) {
      this.tenants.set(tenantId, {
        id: tenantId,
        name: tenantId,
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
      const [id, name, created_at] = values.map(String);
      if (this.tenants.has(id)) return 0;
      this.tenants.set(id, { id, name, created_at, disabled_at: "" });
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
    if (normalized === "SELECT id, name, created_at, disabled_at FROM tenants ORDER BY created_at DESC, name") {
      return [...this.tenants.values()].sort(by("created_at", "name")).reverse();
    }
    if (normalized === "SELECT id, name, created_at, disabled_at FROM tenants WHERE id = ?") {
      const [id] = values.map(String);
      return pick(this.tenants.get(id), ["id", "name", "created_at", "disabled_at"]);
    }
    if (normalized === "SELECT id, tenant_id, token_hash, label, created_at, last_used_at, revoked_at FROM api_keys ORDER BY created_at DESC") {
      return [...this.apiKeys.values()].sort(by("created_at")).reverse();
    }
    if (normalized === "SELECT json FROM cards WHERE tenant_id = ? AND id = ?") {
      const [tenant_id, id] = values.map(String);
      return pick(this.cards.get(`${tenant_id}:${id}`), ["json"]);
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
    if (normalized === "SELECT api_key_hash, device_id, json FROM devices ORDER BY api_key_hash, device_id") {
      return [...this.devices.values()]
        .sort(by("api_key_hash", "device_id"))
        .map(select("api_key_hash", "device_id", "json"));
    }
    if (normalized === "SELECT api_key_hash, device_id, widget_kind, token FROM widget_tokens ORDER BY api_key_hash, device_id, widget_kind") {
      return [...this.widgetTokens.values()]
        .sort(by("api_key_hash", "device_id", "widget_kind"))
        .map(select("api_key_hash", "device_id", "widget_kind", "token"));
    }
    if (normalized === "SELECT api_key_hash, external_id, json FROM activities ORDER BY api_key_hash, external_id") {
      return [...this.activities.values()]
        .sort(by("api_key_hash", "external_id"))
        .map(select("api_key_hash", "external_id", "json"));
    }
    if (normalized === "SELECT api_key_hash, external_id, json FROM pending_activities ORDER BY api_key_hash, external_id") {
      return [...this.pendingActivities.values()]
        .sort(by("api_key_hash", "external_id"))
        .map(select("api_key_hash", "external_id", "json"));
    }
    if (normalized === "SELECT api_key_hash, device_id, attributes_type, token FROM start_tokens ORDER BY api_key_hash, device_id, attributes_type") {
      return [...this.startTokens.values()]
        .sort(by("api_key_hash", "device_id", "attributes_type"))
        .map(select("api_key_hash", "device_id", "attributes_type", "token"));
    }
    if (normalized === "SELECT json FROM pending_activities WHERE tenant_id = ? ORDER BY external_id") {
      const [tenant_id] = values.map(String);
      return byTenant(this.pendingActivities, tenant_id)
        .sort(by("external_id"))
        .map((row) => ({ json: row.json }));
    }
    throw new Error(`Unhandled FakeD1 all SQL: ${normalized}`);
  }
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
