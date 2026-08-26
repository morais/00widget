import { describe, expect, it } from "vitest";
import handler from "../src/index";
import { ApiScopePresets, createApiKey, listTenants } from "../src/auth";
import * as storage from "../src/storage";
import { authedRequest, makeEnv } from "./helpers";

const executionCtx = {} as ExecutionContext;

async function session(env: ReturnType<typeof makeEnv>) {
  const device = await createApiKey(env, {
    ownerEmail: "owner@example.com",
    label: "iPhone",
    kind: "publisher",
    sessionId: "session-1",
    scopes: ApiScopePresets.device,
  });
  const app = await createApiKey(env, {
    tenantId: device.tenant.id,
    ownerEmail: device.tenant.ownerEmail,
    label: "iPhone (app only)",
    kind: "app",
    sessionId: "session-1",
    scopes: ApiScopePresets.appOnly,
  });
  return { device, app };
}

describe("GET /v1/account", () => {
  it("returns the tenant and owner email to the app credential", async () => {
    const env = makeEnv();
    const { device, app } = await session(env);

    const response = await (handler.fetch as any)(
      authedRequest("https://x/v1/account", {}, app.token),
      env,
      executionCtx,
    );
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      account: { tenantId: device.tenant.id, ownerEmail: "owner@example.com" },
    });
  });

  it("refuses the device token, which is the same tenant but not the app", async () => {
    const env = makeEnv();
    const { device } = await session(env);

    const response = await (handler.fetch as any)(
      authedRequest("https://x/v1/account", {}, device.token),
      env,
      executionCtx,
    );
    expect(response.status).toBe(403);
    expect(await response.text()).not.toContain("owner@example.com");
  });

  it("refuses an unauthenticated request", async () => {
    const env = makeEnv();
    await session(env);

    const response = await (handler.fetch as any)(
      new Request("https://x/v1/account"),
      env,
      executionCtx,
    );
    expect(response.status).toBe(401);
  });
});

describe("DELETE /v1/account", () => {
  it("erases the tenant, its content, and every credential", async () => {
    const env = makeEnv();
    const { device, app } = await session(env);
    const tenantId = device.tenant.id;

    // Content across the tables the batch touches. Seeded through storage
    // rather than the API because the device credential deliberately cannot
    // publish — that is the publisher token's job.
    await storage.putCards(env, tenantId, device.apiKey.tokenHash, [{
      id: "solar",
      template: "summary",
      title: "Solar",
      value: "4.2",
      unit: "kW",
      updatedAt: "2026-01-01T00:00:00.000Z",
    } as any]);
    await storage.putWebhookIntegration(env, tenantId, device.apiKey.tokenHash, {
      url: "https://example.com/hook",
      secret: "s3cret",
    } as any);

    expect(await storage.listCards(env, tenantId)).toHaveLength(1);

    const response = await (handler.fetch as any)(
      authedRequest("https://x/v1/account", { method: "DELETE" }, app.token),
      env,
      executionCtx,
    );
    expect(response.status).toBe(200);
    const body = await response.json() as { ok: boolean; deleted: boolean; rowsDeleted: number };
    expect(body.ok).toBe(true);
    expect(body.deleted).toBe(true);
    expect(body.rowsDeleted).toBeGreaterThan(0);

    // Gone, not merely unreachable.
    expect(await storage.listCards(env, tenantId)).toEqual([]);
    expect(await storage.getWebhookIntegration(env, tenantId)).toBeNull();
    expect((await listTenants(env)).some((tenant) => tenant.id === tenantId)).toBe(false);
  });

  it("kills every credential of the session, not just the one that asked", async () => {
    const env = makeEnv();
    const { device, app } = await session(env);

    await (handler.fetch as any)(
      authedRequest("https://x/v1/account", { method: "DELETE" }, app.token),
      env,
      executionCtx,
    );

    for (const token of [app.token, device.token]) {
      const after = await (handler.fetch as any)(
        authedRequest("https://x/v1/cards", {}, token),
        env,
        executionCtx,
      );
      expect(after.status).toBe(401);
    }
  });

  it("refuses the device token: deleting the account is not an agent's act", async () => {
    const env = makeEnv();
    const { device } = await session(env);

    const response = await (handler.fetch as any)(
      authedRequest("https://x/v1/account", { method: "DELETE" }, device.token),
      env,
      executionCtx,
    );
    expect(response.status).toBe(403);
    expect(await storage.listCards(env, device.tenant.id)).toEqual([]);
    expect((await listTenants(env)).some((tenant) => tenant.id === device.tenant.id)).toBe(true);
  });

  it("refuses an unauthenticated request", async () => {
    const env = makeEnv();
    const { device } = await session(env);

    const response = await (handler.fetch as any)(
      new Request("https://x/v1/account", { method: "DELETE" }),
      env,
      executionCtx,
    );
    expect(response.status).toBe(401);
    expect((await listTenants(env)).some((tenant) => tenant.id === device.tenant.id)).toBe(true);
  });

  it("leaves another tenant's account untouched", async () => {
    const env = makeEnv();
    const mine = await session(env);
    const theirs = await createApiKey(env, {
      ownerEmail: "other@example.com",
      label: "Other iPhone",
      kind: "publisher",
      sessionId: "session-2",
      scopes: ApiScopePresets.device,
    });
    await storage.putCards(env, theirs.tenant.id, theirs.apiKey.tokenHash, [{
      id: "washer",
      template: "summary",
      title: "Washer",
      value: "running",
      updatedAt: "2026-01-01T00:00:00.000Z",
    } as any]);

    await (handler.fetch as any)(
      authedRequest("https://x/v1/account", { method: "DELETE" }, mine.app.token),
      env,
      executionCtx,
    );

    expect(await storage.listCards(env, theirs.tenant.id)).toHaveLength(1);
    const after = await (handler.fetch as any)(
      authedRequest("https://x/v1/cards", {}, theirs.token),
      env,
      executionCtx,
    );
    expect(after.status).toBe(200);
  });

  it("detaches a subscription rather than deleting it, so it can be adopted again", async () => {
    const env = makeEnv();
    const { device, app } = await session(env);
    await env.ZW_DB.prepare(
      `INSERT INTO subscriptions (
         original_transaction_id, tenant_id, product_id, status, expires_at_ms,
         grace_expires_at_ms, is_trial, auto_renew, environment, revoked_at_ms,
         signed_date_ms, created_at, updated_at
       ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    )
      .bind("txn-1", device.tenant.id, "monthly", 1, 4102444800000, null, 0, 1, "Production", null, 1, "t", "t")
      .run();

    await (handler.fetch as any)(
      authedRequest("https://x/v1/account", { method: "DELETE" }, app.token),
      env,
      executionCtx,
    );

    // The same read `claimTransactionForTenant` uses: the row survives, and it
    // is unclaimed, which is what lets the purchase be adopted again.
    const row = await env.ZW_DB.prepare(
      `SELECT tenant_id FROM subscriptions WHERE original_transaction_id = ?`,
    )
      .bind("txn-1")
      .first<{ tenant_id: string | null }>();
    expect(row).not.toBeNull();
    expect(row?.tenant_id).toBeNull();
  });
});
