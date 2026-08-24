import { describe, expect, it } from "vitest";
import handler from "../src/index";
import { ApiScopePresets, createApiKey } from "../src/auth";
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
