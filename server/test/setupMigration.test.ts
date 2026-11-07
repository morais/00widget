import { readFileSync, readdirSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { URL } from "node:url";
import { describe, expect, it } from "vitest";

describe("native sign-in backfill (real SQLite)", () => {
  it("backfills only paired native sessions within the same tenant and retains historical evidence", () => {
    const db = new DatabaseSync(":memory:");
    try {
      const migrations = new URL("../migrations/", import.meta.url);
      for (const file of readdirSync(migrations).sort()) {
        if (file.endsWith(".sql") && file < "0039") db.exec(readFileSync(new URL(file, migrations), "utf8"));
      }
      const tenant = db.prepare("INSERT INTO tenants (id, name, created_at) VALUES (?, ?, ?)");
      for (const id of ["native", "web", "connector", "manual", "partial", "cross-tenant", "older"]) {
        tenant.run(id, id, "2026-01-01T00:00:00.000Z");
      }
      db.exec(`INSERT INTO apple_accounts VALUES ('apple-web', 'web', 'private@example.com', '2026-01-01', '2026-01-01')`);
      const key = db.prepare(`INSERT INTO api_keys
        (id, tenant_id, token_hash, label, kind, purpose, session_id, created_at, scopes_json, expires_at, revoked_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, '[]', '2026-01-02', '2026-01-03')`);
      const insert = (id: string, account: string, kind: string, purpose: string, session: string | null, at = "2026-02-01") =>
        key.run(id, account, id, "iOS app", kind, purpose, session, at);
      insert("native-device", "native", "publisher", "device", "valid-session", "2026-01-31");
      insert("native-app", "native", "app", "app", "valid-session");
      insert("newer-device", "native", "publisher", "device", "newer", "2026-04-01");
      insert("newer-app", "native", "app", "app", "newer", "2026-04-02");
      insert("connector", "connector", "publisher", "connector", null);
      insert("manual", "manual", "publisher", "device", null);
      insert("partial", "partial", "publisher", "device", "incomplete");
      insert("foreign-app", "cross-tenant", "app", "app", "incomplete");
      insert("old-device", "older", "publisher", "device", "historical");
      insert("old-app", "older", "app", "app", "historical");
      const migration = readFileSync(new URL("0039_native_sign_in.sql", migrations), "utf8");
      db.exec(migration);
      const rows = db.prepare("SELECT id, first_native_sign_in_at FROM tenants ORDER BY id").all();
      expect(Object.fromEntries(rows.map((row) => [row.id, row.first_native_sign_in_at]))).toEqual({
        native: "2026-02-01", older: "2026-02-01", web: null, connector: null,
        manual: null, partial: null, "cross-tenant": null,
      });
      // Re-running the data backfill never overwrites a timestamp already known.
      db.exec("UPDATE tenants SET first_native_sign_in_at = '2025-12-01' WHERE id = 'native'");
      db.exec(migration.slice(migration.indexOf("UPDATE tenants")));
      expect(db.prepare("SELECT first_native_sign_in_at FROM tenants WHERE id = 'native'").get())
        .toMatchObject({ first_native_sign_in_at: "2025-12-01" });
    } finally {
      db.close();
    }
  });
});
