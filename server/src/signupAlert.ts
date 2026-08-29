import type { Env } from "./types";

/// Operator notification when self-service signup creates a brand new tenant.
///
/// Off unless *both* the `SIGNUP_ALERTS` send_email binding and
/// `SIGNUP_ALERT_TO` are configured, so a default deployment — which has
/// neither — sends nothing and needs no Email Routing setup at all. This exists
/// because `APPLE_APP_LOGIN_ENABLED=true` lets anyone with a verified Apple ID
/// create a tenant, and an operator running that open should find out when it
/// happens rather than discovering it in a bill.
export function signupAlertsConfigured(env: Env): boolean {
  return Boolean(env.SIGNUP_ALERTS && env.SIGNUP_ALERT_TO?.trim());
}

export interface NewTenantAlert {
  source: "app" | "web";
  tenantId: string;
  ownerEmail: string;
  createdAt: string;
}

/// Never throws and never rejects. A signup must not fail, or even slow down,
/// because an alert could not be delivered — callers pass this to
/// `ctx.waitUntil`, which runs it after the response is already on its way.
export async function sendNewTenantAlert(env: Env, alert: NewTenantAlert): Promise<void> {
  if (!signupAlertsConfigured(env)) return;

  const to = env.SIGNUP_ALERT_TO!.trim();
  // Must be an address on a domain this account has Email Routing configured
  // for; Cloudflare rejects anything else at send time.
  const from = env.SIGNUP_ALERT_FROM?.trim() || to;

  try {
    // Imported dynamically rather than at module scope: `cloudflare:email` only
    // resolves inside the Workers runtime, and the test suite runs in plain
    // Node, where a top-level import would fail the entire file on load.
    const { EmailMessage } = await import("cloudflare:email");

    // Defence at the sink as well as the boundary. Every path that writes an
    // owner_email now validates it, but this function hand-assembles a
    // CRLF-delimited message, and a header built from a value that turns out to
    // carry a newline is an injected Bcc. Rejecting at the boundary is the real
    // control; this is what makes the sink safe regardless of what reaches it.
    const subject = headerSafe(`00Widget: new tenant ${alert.ownerEmail}`);
    const signupFlag = alert.source === "web" ? "WEB_SIGNUP_ENABLED" : "APPLE_APP_LOGIN_ENABLED";
    const signupSurface = alert.source === "web" ? "web OAuth" : "native app";
    const body = [
      "A new tenant was created through Sign in with Apple.",
      "",
      `Signup surface: ${signupSurface}`,
      `Owner email: ${alert.ownerEmail}`,
      `Tenant id:   ${alert.tenantId}`,
      `Created at:  ${alert.createdAt}`,
      "",
      `Self-service signup is controlled by ${signupFlag}.`,
      "Set it to anything other than \"true\" to close it.",
    ].join("\n");

    const raw = [
      `From: 00Widget <${headerSafe(from)}>`,
      `To: ${headerSafe(to)}`,
      `Subject: ${subject}`,
      `Date: ${new Date().toUTCString()}`,
      `Message-ID: <${crypto.randomUUID()}@00widget.com>`,
      "MIME-Version: 1.0",
      "Content-Type: text/plain; charset=UTF-8",
      "Content-Transfer-Encoding: 7bit",
      "",
      body,
    ].join("\r\n");

    await env.SIGNUP_ALERTS!.send(new EmailMessage(from, to, raw));
  } catch (error) {
    // Logged, not surfaced: the tenant exists either way, and the caller has
    // already returned credentials to the client.
    console.warn("signup alert email failed", {
      tenantId: alert.tenantId,
      error: error instanceof Error ? error.message : String(error),
    });
  }
}

/// Strips anything that would end a header line. C0 controls and DEL have no
/// legitimate place in an address or a subject, so removing them cannot damage
/// a real value.
function headerSafe(value: string): string {
  return value.replace(/[\u0000-\u001f\u007f]/g, "");
}
