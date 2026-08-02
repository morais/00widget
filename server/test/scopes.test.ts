import { describe, expect, it } from "vitest";
import handler from "../src/index";
import { ApiScopePresets, createApiKey } from "../src/auth";
import { authedRequest, makeEnv, seedApiKey } from "./helpers";

const ctx = {} as ExecutionContext;

describe("API credential scopes", () => {
  it("fails closed before every scoped handler when a credential has no permissions", async () => {
    const env = makeEnv({ SHARING_ENABLED: "true" });
    await seedApiKey(env, "no-scopes", "test-tenant", "publisher", "", "", undefined, []);

    const routes: Array<[string, string]> = [
      ["POST", "/v1/cards/upsert"],
      ["POST", "/v1/cards/upsert-batch"],
      ["GET", "/v1/cards"],
      ["GET", "/v1/dashboard"],
      ["GET", "/v1/cards/example"],
      ["DELETE", "/v1/cards/example"],
      ["POST", "/v1/devices/register"],
      ["POST", "/v1/widgets/register-push-token"],
      ["POST", "/v1/live-activities/register"],
      ["POST", "/v1/live-activities/register-start-token"],
      ["POST", "/v1/live-activities/start"],
      ["GET", "/v1/live-activities/pending"],
      ["GET", "/v1/live-activities"],
      ["POST", "/v1/live-activities/update"],
      ["POST", "/v1/live-activities/end"],
      ["GET", "/v1/integrations/webhook"],
      ["PUT", "/v1/integrations/webhook"],
      ["DELETE", "/v1/integrations/webhook"],
      ["POST", "/v1/actions/example/run"],
      ["POST", "/v1/shares"],
      ["GET", "/v1/shares/outgoing"],
      ["GET", "/v1/shares/incoming"],
      ["POST", "/v1/shares/example/accept"],
      ["POST", "/v1/shares/example/decline"],
      ["DELETE", "/v1/shares/example"],
    ];

    for (const [method, path] of routes) {
      const response = await (handler.fetch as any)(
        authedRequest(`https://x${path}`, { method }, "no-scopes"),
        env,
        ctx,
      );
      expect(response.status, `${method} ${path}`).toBe(403);
      expect((await response.json()) as { error: string }).toMatchObject({
        error: expect.stringContaining("API scope"),
      });
    }

    await seedApiKey(env, "app-no-scopes", "test-tenant", "app", "", "", undefined, []);
    const confirmed = await (handler.fetch as any)(
      authedRequest("https://x/v1/actions/example/run-confirmed", { method: "POST" }, "app-no-scopes"),
      env,
      ctx,
    );
    expect(confirmed.status).toBe(403);
    expect((await confirmed.json()) as { error: string }).toMatchObject({
      error: "API scope 'actions:confirm' required",
    });
  });

  it("keeps producer, device, app-only, and webhook capabilities separated", async () => {
    const env = makeEnv({ SHARING_ENABLED: "true" });
    const producer = await createApiKey(env, {
      tenantId: "test-tenant",
      scopes: ApiScopePresets.producer,
    });
    const device = await createApiKey(env, {
      tenantId: "test-tenant",
      scopes: ApiScopePresets.device,
    });
    const appOnly = await createApiKey(env, {
      tenantId: "test-tenant",
      kind: "app",
      scopes: ApiScopePresets.appOnly,
    });
    const webhook = await createApiKey(env, {
      tenantId: "test-tenant",
      scopes: ApiScopePresets.webhookManager,
    });

    expect(await status(env, producer.token, "GET", "/v1/cards")).toBe(200);
    expect(await status(env, producer.token, "POST", "/v1/devices/register")).toBe(403);
    expect(await status(env, producer.token, "GET", "/v1/integrations/webhook")).toBe(403);

    expect(await status(env, device.token, "GET", "/v1/cards")).toBe(200);
    expect(await status(env, device.token, "POST", "/v1/cards/upsert")).toBe(403);
    expect(await status(env, device.token, "GET", "/v1/shares/incoming")).toBe(403);

    expect(await status(env, appOnly.token, "GET", "/v1/shares/incoming")).toBe(200);
    expect(await status(env, appOnly.token, "GET", "/v1/cards")).toBe(403);

    const webhookCreate = await (handler.fetch as any)(
      authedRequest("https://x/v1/integrations/webhook", {
        method: "PUT",
        body: JSON.stringify({ url: "https://example.com/actions" }),
      }, webhook.token),
      env,
      ctx,
    );
    expect(webhookCreate.status).toBe(200);
    expect(await status(env, webhook.token, "POST", "/v1/cards/upsert")).toBe(403);
  });
});

async function status(
  env: ReturnType<typeof makeEnv>,
  token: string,
  method: string,
  path: string,
): Promise<number> {
  const response = await (handler.fetch as any)(
    authedRequest(`https://x${path}`, { method }, token),
    env,
    ctx,
  );
  return response.status;
}
