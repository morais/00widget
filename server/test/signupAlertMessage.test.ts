import { describe, expect, it, vi } from "vitest";
import { sendNewTenantAlert } from "../src/signupAlert";
import { makeEnv } from "./helpers";

// `cloudflare:email` only resolves inside the Workers runtime. Standing in for
// it lets the hand-built message be read back, which is the only way to check
// what each signup surface actually says.
vi.mock("cloudflare:email", () => ({
  EmailMessage: class {
    constructor(readonly from: string, readonly to: string, readonly raw: string) {}
  },
}));

async function sentMessage(alert: Parameters<typeof sendNewTenantAlert>[1]): Promise<string> {
  const send = vi.fn(async (_message: { raw: string }) => {});
  const env = makeEnv({ SIGNUP_ALERTS: { send } as any, SIGNUP_ALERT_TO: "ops@example.com" });
  await sendNewTenantAlert(env, alert);
  expect(send).toHaveBeenCalledTimes(1);
  return send.mock.calls[0][0].raw;
}

describe("signup alert message", () => {
  it("names the Horizon surface and its flag, with no owner email", async () => {
    const raw = await sentMessage({ source: "horizon", tenantId: "t-h", createdAt: "2026-10-02T00:00:00.000Z" });
    expect(raw).toContain("Subject: 00Widget: new tenant via Horizon OS app\r\n");
    expect(raw).toContain("A new tenant was created through a Meta account.");
    expect(raw).toContain("Owner email: (none)");
    expect(raw).toContain("Tenant id:   t-h");
    expect(raw).toContain("controlled by HORIZON_IDENTITY_ENABLED.");
  });

  it("keeps the Apple surfaces as they were", async () => {
    const app = await sentMessage({
      source: "app", tenantId: "t-a", ownerEmail: "new@example.com", createdAt: "2026-10-02T00:00:00.000Z",
    });
    expect(app).toContain("Subject: 00Widget: new tenant new@example.com\r\n");
    expect(app).toContain("A new tenant was created through Sign in with Apple.");
    expect(app).toContain("Signup surface: native app");
    expect(app).toContain("controlled by APPLE_APP_LOGIN_ENABLED.");

    const web = await sentMessage({
      source: "web", tenantId: "t-w", ownerEmail: "new@example.com", createdAt: "2026-10-02T00:00:00.000Z",
    });
    expect(web).toContain("Signup surface: web OAuth");
    expect(web).toContain("controlled by WEB_SIGNUP_ENABLED.");
  });
});
