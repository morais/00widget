import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { ACCOUNT_DELETION_EXEMPT_TABLES, TENANT_SCOPED_TABLES } from "../src/account";

/// Guards the one list that account deletion is.
///
/// Nothing in the schema enumerates tenant-scoped tables, and there are no
/// cascading deletes, so a table added without a line in `TENANT_SCOPED_TABLES`
/// keeps its rows after the account is deleted — silently, and with every other
/// test still green. This reads the migrations the way D1 applies them and
/// insists that every surviving table with a tenant column is either swept or
/// exempted with a stated reason.

const MIGRATIONS = join(__dirname, "..", "migrations");
const TENANT_COLUMNS = ["tenant_id", "owner_tenant_id", "target_tenant_id", "recipient_tenant_id"];

interface TableDefinition {
  name: string;
  body: string;
}

/// The tables that exist once every migration has run, with the body of the
/// CREATE that last defined each — later migrations drop and recreate tables,
/// so only the final definition says what a table holds today.
function liveTables(): Map<string, TableDefinition> {
  const tables = new Map<string, TableDefinition>();
  const files = readdirSync(MIGRATIONS).filter((name) => name.endsWith(".sql")).sort();

  for (const file of files) {
    const sql = readFileSync(join(MIGRATIONS, file), "utf8");

    for (const match of sql.matchAll(
      /CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?["`]?(\w+)["`]?\s*\(([\s\S]*?)\n\s*\);/gi,
    )) {
      tables.set(match[1], { name: match[1], body: match[2] });
    }
    for (const match of sql.matchAll(/DROP\s+TABLE\s+(?:IF\s+EXISTS\s+)?["`]?(\w+)["`]?/gi)) {
      tables.delete(match[1]);
    }
    for (const match of sql.matchAll(
      /ALTER\s+TABLE\s+["`]?(\w+)["`]?\s+RENAME\s+TO\s+["`]?(\w+)["`]?/gi,
    )) {
      const existing = tables.get(match[1]);
      if (!existing) continue;
      tables.delete(match[1]);
      tables.set(match[2], { name: match[2], body: existing.body });
    }
  }
  return tables;
}

describe("account deletion covers the schema", () => {
  it("finds the tables it is supposed to be reading", () => {
    const tables = liveTables();
    // A sanity check on the parser rather than on the code: if this regex ever
    // stops matching, every assertion below would pass by finding nothing.
    expect(tables.has("tenants")).toBe(true);
    expect(tables.has("cards")).toBe(true);
    expect(tables.size).toBeGreaterThan(15);
    // Replaced by activity_instances in 0017 and dropped there.
    expect(tables.has("activities")).toBe(false);
  });

  it("sweeps or exempts every table that holds tenant data", () => {
    const uncovered: string[] = [];
    for (const [name, definition] of liveTables()) {
      const holdsTenantData =
        name === "tenants" || TENANT_COLUMNS.some((column) =>
          new RegExp(`\\b${column}\\b`).test(definition.body),
        );
      if (!holdsTenantData) continue;
      if (name in TENANT_SCOPED_TABLES) continue;
      if (name in ACCOUNT_DELETION_EXEMPT_TABLES) continue;
      uncovered.push(name);
    }
    expect(uncovered).toEqual([]);
  });

  it("names only tables that still exist", () => {
    const tables = liveTables();
    for (const name of Object.keys(TENANT_SCOPED_TABLES)) {
      expect(tables.has(name), `${name} is swept but no longer exists`).toBe(true);
    }
  });

  it("sweeps by columns the tables actually have", () => {
    const tables = liveTables();
    for (const [name, columns] of Object.entries(TENANT_SCOPED_TABLES)) {
      const body = tables.get(name)?.body ?? "";
      for (const column of columns) {
        expect(
          new RegExp(`\\b${column}\\b`).test(body),
          `${name} has no column ${column}`,
        ).toBe(true);
      }
    }
  });
});
