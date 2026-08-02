import type { Env, WidgetReloadQueueMessage } from "./types";
import {
  requireAuth,
  AuthError,
  hasScope,
  type ApiScope,
  type CredentialKind,
} from "./auth";
import { json, notFound, unauthorized } from "./http";
import * as cards from "./cards";
import * as devices from "./devices";
import * as widgets from "./widgets";
import * as liveActivities from "./liveActivities";
import * as actions from "./actions";
import * as admin from "./admin";
import * as appLogin from "./appLogin";
import * as landing from "./landing";
import * as shares from "./shares";
import * as dashboard from "./dashboard";
import * as sessions from "./sessions";
import { processPendingWidgetReload } from "./widgetPush";

interface Route {
  method: string;
  pattern: RegExp;
  handler: (
    req: Request,
    env: Env,
    match: RegExpExecArray,
    ctx: ExecutionContext,
  ) => Promise<Response>;
}

const routes: Route[] = [
  {
    method: "GET",
    pattern: /^\/health\/?$/,
    handler: async () => json({ ok: true }),
  },
  // Public landing + API docs.
  { method: "GET", pattern: /^\/?$/, handler: (req) => landing.handleLanding(req) },
  { method: "GET", pattern: /^\/llms\.md\/?$/, handler: (req) => landing.handleLlmsMd(req) },
  { method: "GET", pattern: /^\/llms\.txt\/?$/, handler: (req) => landing.handleLlmsTxt(req) },
  authed("POST", /^\/v1\/cards\/upsert\/?$/, "publish", (req, env, auth, _match, ctx) =>
    cards.upsertCard(req, env, auth, ctx)),
  authed("POST", /^\/v1\/cards\/upsert-batch\/?$/, "publish", (req, env, auth, _match, ctx) =>
    cards.upsertCardsBatch(req, env, auth, ctx)),
  authed("GET", /^\/v1\/cards\/?$/, "tenant:read", (req, env, auth) => cards.listCards(req, env, auth)),
  authed("GET", /^\/v1\/dashboard\/?$/, "tenant:read", (req, env, auth) =>
    dashboard.getDashboard(req, env, auth),
  ),
  authed("GET", /^\/v1\/cards\/([^/]+)\/?$/, "tenant:read", (req, env, auth, m) => cards.getCard(req, env, auth, m[1])),
  authed("DELETE", /^\/v1\/cards\/([^/]+)\/?$/, "publish", (req, env, auth, m, ctx) =>
    cards.deleteCard(req, env, auth, m[1], ctx)),
  authed("POST", /^\/v1\/devices\/register\/?$/, "device:register", (req, env, auth) => devices.registerDevice(req, env, auth)),
  authed("POST", /^\/v1\/widgets\/register-push-token\/?$/, "device:register", (req, env, auth) =>
    widgets.registerWidgetPushToken(req, env, auth),
  ),
  authed("POST", /^\/v1\/live-activities\/register\/?$/, "device:register", (req, env, auth) =>
    liveActivities.registerLiveActivity(req, env, auth),
  ),
  authed("POST", /^\/v1\/live-activities\/register-start-token\/?$/, "device:register", (req, env, auth) =>
    liveActivities.registerLiveActivityStartToken(req, env, auth),
  ),
  authed("POST", /^\/v1\/live-activities\/start\/?$/, "publish", (req, env, auth) =>
    liveActivities.startLiveActivity(req, env, auth),
  ),
  authed("GET", /^\/v1\/live-activities\/pending\/?$/, "tenant:read", (req, env, auth) =>
    liveActivities.pendingActivities(req, env, auth),
  ),
  authed("GET", /^\/v1\/live-activities\/?$/, "tenant:read", (req, env, auth) =>
    liveActivities.activeActivities(req, env, auth),
  ),
  authed("POST", /^\/v1\/live-activities\/update\/?$/, "publish", (req, env, auth) =>
    liveActivities.updateLiveActivity(req, env, auth),
  ),
  authed("POST", /^\/v1\/live-activities\/end\/?$/, "publish", (req, env, auth) =>
    liveActivities.endLiveActivity(req, env, auth),
  ),
  authed("GET", /^\/v1\/integrations\/webhook\/?$/, "webhook:manage", (req, env, auth) =>
    actions.getWebhookIntegration(req, env, auth),
  ),
  authed("PUT", /^\/v1\/integrations\/webhook\/?$/, "webhook:manage", (req, env, auth) =>
    actions.putWebhookIntegration(req, env, auth),
  ),
  authed("DELETE", /^\/v1\/integrations\/webhook\/?$/, "webhook:manage", (req, env, auth) =>
    actions.deleteWebhookIntegration(req, env, auth),
  ),
  authed("POST", /^\/v1\/actions\/([^/]+)\/run\/?$/, "actions:run", (req, env, auth, m, ctx) =>
    actions.runAction(req, env, auth, m[1], ctx),
  ),
  authed("POST", /^\/v1\/actions\/([^/]+)\/run-confirmed\/?$/, "actions:confirm", (req, env, auth, m, ctx) =>
    actions.runConfirmedAction(req, env, auth, m[1], ctx), { credentialKind: "app" },
  ),
  authed("POST", /^\/v1\/shares\/?$/, "shares:manage", (req, env, auth) => shares.createShare(req, env, auth)),
  authed("GET", /^\/v1\/shares\/outgoing\/?$/, "shares:manage", (req, env, auth) => shares.listOutgoing(req, env, auth)),
  authed("GET", /^\/v1\/shares\/incoming\/?$/, "shares:manage", (req, env, auth) => shares.listIncoming(req, env, auth)),
  authed("POST", /^\/v1\/shares\/([^/]+)\/accept\/?$/, "shares:manage", (req, env, auth, m) =>
    shares.acceptShare(req, env, auth, m[1]),
  ),
  authed("POST", /^\/v1\/shares\/([^/]+)\/decline\/?$/, "shares:manage", (req, env, auth, m) =>
    shares.declineShare(req, env, auth, m[1]),
  ),
  authed("DELETE", /^\/v1\/shares\/([^/]+)\/?$/, "shares:manage", (req, env, auth, m) =>
    shares.revokeShare(req, env, auth, m[1]),
  ),
  { method: "POST", pattern: /^\/v1\/auth\/apple\/token\/?$/, handler: (req, env) =>
    appLogin.createTokenFromApple(req, env),
  },
  authed("DELETE", /^\/v1\/auth\/token\/?$/, null, (req, env, auth) =>
    sessions.revokeCurrentCredential(req, env, auth), { allowExpired: true },
  ),
  // Admin dashboard — gated by Apple Sign-In or API-token cookie.
  { method: "GET", pattern: /^\/admin\/login\/?$/, handler: (req, env) => admin.handleAdminLogin(req, env) },
  { method: "GET", pattern: /^\/admin\/login\/apple\/?$/, handler: (req, env) => admin.handleAdminLoginApple(req, env) },
  { method: "POST", pattern: /^\/admin\/login\/api-token\/?$/, handler: (req, env) => admin.handleAdminLoginApiToken(req, env) },
  { method: "POST", pattern: /^\/admin\/auth\/apple\/callback\/?$/, handler: (req, env) => admin.handleAdminCallback(req, env) },
  { method: "POST", pattern: /^\/admin\/api-keys\/?$/, handler: (req, env) => admin.handleAdminCreateApiKey(req, env) },
  { method: "POST", pattern: /^\/admin\/api-keys\/([^/]+)\/revoke\/?$/, handler: (req, env, match) =>
    admin.handleAdminRevokeApiKey(req, env, match[1]),
  },
  { method: "POST", pattern: /^\/admin\/tenants\/([^/]+)\/cards\/([^/]+)\/delete\/?$/, handler: (req, env, match, ctx) =>
    admin.handleAdminDeleteCard(req, env, match[1], match[2], ctx),
  },
  { method: "POST", pattern: /^\/admin\/tenants\/([^/]+)\/widget-tokens\/([^/]+)\/([^/]+)\/delete\/?$/, handler: (req, env, match) =>
    admin.handleAdminDeleteWidgetToken(req, env, match[1], match[2], match[3]),
  },
  { method: "POST", pattern: /^\/admin\/tenants\/([^/]+)\/live-activities\/([^/]+)\/delete\/?$/, handler: (req, env, match) =>
    admin.handleAdminDeleteLiveActivity(req, env, match[1], match[2]),
  },
  { method: "POST", pattern: /^\/admin\/tenants\/([^/]+)\/pending-live-activities\/([^/]+)\/delete\/?$/, handler: (req, env, match) =>
    admin.handleAdminDeletePendingLiveActivity(req, env, match[1], match[2]),
  },
  { method: "POST", pattern: /^\/admin\/tenants\/([^/]+)\/start-tokens\/([^/]+)\/([^/]+)\/delete\/?$/, handler: (req, env, match) =>
    admin.handleAdminDeleteStartToken(req, env, match[1], match[2], match[3]),
  },
  { method: "GET", pattern: /^\/admin\/logout\/?$/, handler: (req, env) => admin.handleAdminLogout(req, env) },
  { method: "GET", pattern: /^\/admin\/?$/, handler: (req, env) => admin.handleAdminDashboard(req, env) },
];

type AuthedHandler = (
  req: Request,
  env: Env,
  auth: import("./auth").AuthContext,
  match: RegExpExecArray,
  ctx: ExecutionContext,
) => Promise<Response>;

function authed(
  method: string,
  pattern: RegExp,
  requiredScope: ApiScope | null,
  handler: AuthedHandler,
  options: { credentialKind?: CredentialKind; allowExpired?: boolean } = {},
): Route {
  return {
    method,
    pattern,
    handler: async (req, env, match, ctx) => {
      try {
        const auth = await requireAuth(req, env, { allowExpired: options.allowExpired });
        if (options.credentialKind && auth.credentialKind !== options.credentialKind) {
          return json({ error: `${options.credentialKind} credential required` }, 403);
        }
        if (requiredScope && !hasScope(auth, requiredScope)) {
          return json({ error: `API scope '${requiredScope}' required` }, 403);
        }
        return await handler(req, env, auth, match, ctx);
      } catch (err) {
        if (err instanceof AuthError) return unauthorized(err.message);
        throw err;
      }
    },
  };
}

const handler: ExportedHandler<Env, WidgetReloadQueueMessage> = {
  async fetch(req, env, ctx) {
    const url = new URL(req.url);
    for (const route of routes) {
      if (route.method !== req.method) continue;
      const match = route.pattern.exec(url.pathname);
      if (!match) continue;
      try {
        return preventSensitiveResponseCaching(
          url.pathname,
          await route.handler(req, env, match, ctx),
        );
      } catch (err) {
        console.error("handler error", err);
        return preventSensitiveResponseCaching(
          url.pathname,
          json({ error: "internal error" }, 500),
        );
      }
    }
    return preventSensitiveResponseCaching(url.pathname, notFound());
  },
  async queue(batch: MessageBatch<WidgetReloadQueueMessage>, env) {
    for (const message of batch.messages) {
      try {
        if (!message.body || typeof message.body.tenantId !== "string") {
          console.error("invalid widget reload queue message");
          message.ack();
          continue;
        }
        const outcome = await processPendingWidgetReload(env, message.body);
        if (outcome.retryAfterSeconds) {
          message.retry({ delaySeconds: outcome.retryAfterSeconds });
        } else {
          message.ack();
        }
      } catch (error) {
        console.error("widget reload queue delivery failed", {
          tenantId: message.body?.tenantId,
          error: error instanceof Error ? error.message : String(error),
        });
        message.retry({ delaySeconds: 5 * 60 });
      }
    }
  },
};

function preventSensitiveResponseCaching(pathname: string, response: Response): Response {
  const sensitive = pathname === "/v1"
    || pathname.startsWith("/v1/")
    || pathname === "/admin"
    || pathname.startsWith("/admin/");
  if (sensitive) {
    response.headers.set("cache-control", "no-store");
  }
  return response;
}

export default handler;
