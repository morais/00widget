import type { Env, WidgetReloadQueueMessage } from "./types";
import {
  requireAuth,
  AuthError,
  AuthRateLimitError,
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
import * as appleAppSite from "./appleAppSite";
import * as guestLinks from "./guestLinks";
import * as guestPage from "./guestPage";
import * as landing from "./landing";
import * as webLogin from "./webLogin";
import * as mcp from "./mcp";
import * as mcpOAuth from "./mcpOAuth";
import * as shares from "./shares";
import * as dashboard from "./dashboard";
import * as sessions from "./sessions";
import * as status from "./status";
import * as subscription from "./subscription";
import { processPendingWidgetReload } from "./widgetPush";
import { sweepExpiredRateLimitBuckets } from "./rateLimit";

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
  { method: "GET", pattern: /^\/?$/, handler: (req, env) => landing.handleLanding(req, env) },
  { method: "GET", pattern: /^\/llms\.md\/?$/, handler: (req) => landing.handleLlmsMd(req) },
  // Browser fallback for a guest link. Only reachable by people without the
  // app installed; everyone else has /app/* routed into the app by iOS.
  { method: "GET", pattern: /^\/app\/g\/?$/, handler: (req) => guestPage.handleGuestPage(req) },
  // Associated domains. No trailing-slash variant: Apple fetches this exact
  // path and does not follow redirects.
  { method: "GET", pattern: /^\/\.well-known\/apple-app-site-association$/, handler: (req, env) =>
    appleAppSite.handleAppleAppSiteAssociation(req, env),
  },
  { method: "GET", pattern: /^\/llms\.txt\/?$/, handler: (req, env) => landing.handleLlmsTxt(req, env) },
  // MCP. The endpoint authenticates itself (it must answer an anonymous
  // request with the WWW-Authenticate challenge that starts the OAuth flow),
  // so it is not wrapped in `authed`.
  { method: "POST", pattern: /^\/mcp\/?$/, handler: (req, env, _match, ctx) => mcp.handleMcp(req, env, ctx) },
  { method: "GET", pattern: /^\/mcp\/?$/, handler: (req, env) => mcp.handleMcpMethodNotAllowed(req, env) },
  { method: "GET", pattern: /^\/mcp\.json\/?$/, handler: (req, env) => mcp.handleMcpConfig(req, env) },
  // OAuth discovery. RFC 9728 lets a client look for the protected-resource
  // document either at the bare well-known path or with the resource's own path
  // appended, and clients differ on which they try first.
  { method: "GET", pattern: /^\/\.well-known\/oauth-protected-resource(?:\/mcp)?\/?$/, handler: (req, env) =>
    mcpOAuth.handleProtectedResourceMetadata(req, env),
  },
  { method: "GET", pattern: /^\/\.well-known\/oauth-authorization-server(?:\/mcp)?\/?$/, handler: (req, env) =>
    mcpOAuth.handleAuthorizationServerMetadata(req, env),
  },
  { method: "POST", pattern: /^\/oauth\/register\/?$/, handler: (req, env) => mcpOAuth.handleRegister(req, env) },
  { method: "POST", pattern: /^\/oauth\/token\/?$/, handler: (req, env) => mcpOAuth.handleToken(req, env) },
  // App Store Server Notifications V2. Apple presents no credential — the JWS
  // signature on the body is the authentication — so this cannot be wrapped in
  // `authed`.
  { method: "POST", pattern: /^\/v1\/apple\/subscription-notifications\/?$/, handler: (req, env) =>
    subscription.handleAppleNotification(req, env),
  },
  authed("POST", /^\/v1\/cards\/upsert\/?$/, "publish", (req, env, auth, _match, ctx) =>
    cards.upsertCard(req, env, auth, ctx)),
  authed("POST", /^\/v1\/cards\/upsert-batch\/?$/, "publish", (req, env, auth, _match, ctx) =>
    cards.upsertCardsBatch(req, env, auth, ctx)),
  authed("GET", /^\/v1\/cards\/?$/, "read", (req, env, auth) => cards.listCards(req, env, auth)),
  authed("GET", /^\/v1\/dashboard\/?$/, "read", (req, env, auth) =>
    dashboard.getDashboard(req, env, auth),
  ),
  // Never gated on a subscription: a lapsed account is exactly the one that
  // needs to find out why its writes are failing.
  authed("GET", /^\/v1\/status\/?$/, "read", (req, env, auth) =>
    status.getStatus(req, env, auth),
  ),
  authed("GET", /^\/v1\/cards\/([^/]+)\/?$/, "read", (req, env, auth, m) => cards.getCard(req, env, auth, pathParam(m[1]))),
  authed("DELETE", /^\/v1\/cards\/([^/]+)\/?$/, "publish", (req, env, auth, m, ctx) =>
    cards.deleteCard(req, env, auth, pathParam(m[1]), ctx)),
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
  authed("POST", /^\/v1\/live-activities\/recover\/?$/, "device:register", (req, env, auth) =>
    liveActivities.recoverLiveActivities(req, env, auth),
  ),
  authed("POST", /^\/v1\/live-activities\/start\/?$/, "publish", (req, env, auth) =>
    liveActivities.startLiveActivity(req, env, auth),
  ),
  authed("GET", /^\/v1\/live-activities\/pending\/?$/, "read", (req, env, auth) =>
    liveActivities.pendingActivities(req, env, auth),
  ),
  authed("GET", /^\/v1\/live-activities\/?$/, "read", (req, env, auth) =>
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
    actions.runAction(req, env, auth, pathParam(m[1]), ctx),
  ),
  authed("POST", /^\/v1\/actions\/([^/]+)\/run-confirmed\/?$/, "actions:confirm", (req, env, auth, m, ctx) =>
    actions.runConfirmedAction(req, env, auth, pathParam(m[1]), ctx), { credentialKind: "app" },
  ),
  authed("POST", /^\/v1\/shares\/?$/, "shares:manage", (req, env, auth) => shares.createShare(req, env, auth)),
  authed("GET", /^\/v1\/shares\/outgoing\/?$/, "shares:manage", (req, env, auth) => shares.listOutgoing(req, env, auth)),
  authed("GET", /^\/v1\/shares\/incoming\/?$/, "shares:manage", (req, env, auth) => shares.listIncoming(req, env, auth)),
  // Guest links. Minting and managing needs the owner's credential; the two
  // /v1/guest/* routes are the only thing a guest credential can reach, which
  // the "guest:read" scope enforces on its own — every other route requires a
  // scope the guest preset does not contain.
  authed("POST", /^\/v1\/shares\/guest\/?$/, "shares:manage", (req, env, auth) =>
    guestLinks.createGuestLink(req, env, auth),
  ),
  authed("GET", /^\/v1\/shares\/guest\/?$/, "shares:manage", (req, env, auth) =>
    guestLinks.listGuestLinks(req, env, auth),
  ),
  authed("DELETE", /^\/v1\/shares\/guest\/([^/]+)\/?$/, "shares:manage", (req, env, auth, m) =>
    guestLinks.revokeGuestLink(req, env, auth, pathParam(m[1])),
  ),
  authed("GET", /^\/v1\/guest\/resource\/?$/, "guest:read", (req, env, auth) =>
    guestLinks.getGuestResource(req, env, auth), { credentialKind: "guest" },
  ),
  authed("POST", /^\/v1\/guest\/live-activities\/register\/?$/, "guest:read", (req, env, auth) =>
    guestLinks.registerGuestActivity(req, env, auth), { credentialKind: "guest" },
  ),
  authed("POST", /^\/v1\/shares\/([^/]+)\/accept\/?$/, "shares:manage", (req, env, auth, m) =>
    shares.acceptShare(req, env, auth, pathParam(m[1])),
  ),
  authed("POST", /^\/v1\/shares\/([^/]+)\/decline\/?$/, "shares:manage", (req, env, auth, m) =>
    shares.declineShare(req, env, auth, pathParam(m[1])),
  ),
  authed("DELETE", /^\/v1\/shares\/([^/]+)\/?$/, "shares:manage", (req, env, auth, m) =>
    shares.revokeShare(req, env, auth, pathParam(m[1])),
  ),
  { method: "POST", pattern: /^\/v1\/auth\/apple\/token\/?$/, handler: (req, env, _match, ctx) =>
    appLogin.createTokenFromApple(req, env, ctx),
  },
  // Subscription routes are never themselves gated on holding a subscription:
  // proving you have paid must work from a lapsed account, or renewing is
  // impossible.
  authed("POST", /^\/v1\/subscription\/verify\/?$/, "read", (req, env, auth) =>
    subscription.verifySubscription(req, env, auth)),
  authed("GET", /^\/v1\/subscription\/?$/, "read", (req, env, auth) =>
    subscription.getSubscription(req, env, auth)),

  authed("DELETE", /^\/v1\/auth\/token\/?$/, null, (req, env, auth) =>
    sessions.revokeCurrentCredential(req, env, auth), { allowExpired: true },
  ),
  // Admin dashboard. Every route asserts the admin capability on top of a
  // web session; being signed in is never sufficient.
  // Web sign-in. Not under /admin: authenticating says who you are, and only
  // some of the people who do it are administrators.
  { method: "GET", pattern: /^\/login\/?$/, handler: (req, env) => webLogin.handleLogin(req, env) },
  { method: "GET", pattern: /^\/login\/apple\/?$/, handler: (req, env) => webLogin.handleLoginApple(req, env) },
  { method: "POST", pattern: /^\/login\/api-token\/?$/, handler: (req, env) => webLogin.handleLoginApiToken(req, env) },
  { method: "POST", pattern: /^\/auth\/apple\/callback\/?$/, handler: (req, env) => webLogin.handleAppleCallback(req, env) },
  { method: "GET", pattern: /^\/logout\/?$/, handler: (req, env) => webLogin.handleLogout(req, env) },
  { method: "POST", pattern: /^\/admin\/api-keys\/?$/, handler: (req, env) => admin.handleAdminCreateApiKey(req, env) },
  { method: "POST", pattern: /^\/admin\/api-keys\/([^/]+)\/revoke\/?$/, handler: (req, env, match) =>
    admin.handleAdminRevokeApiKey(req, env, pathParam(match[1])),
  },
  { method: "POST", pattern: /^\/admin\/tenants\/([^/]+)\/cards\/([^/]+)\/delete\/?$/, handler: (req, env, match, ctx) =>
    admin.handleAdminDeleteCard(req, env, pathParam(match[1]), pathParam(match[2]), ctx),
  },
  { method: "POST", pattern: /^\/admin\/tenants\/([^/]+)\/widget-tokens\/([^/]+)\/([^/]+)\/delete\/?$/, handler: (req, env, match) =>
    admin.handleAdminDeleteWidgetToken(req, env, pathParam(match[1]), pathParam(match[2]), pathParam(match[3])),
  },
  { method: "POST", pattern: /^\/admin\/tenants\/([^/]+)\/live-activities\/([^/]+)\/delete\/?$/, handler: (req, env, match) =>
    admin.handleAdminDeleteLiveActivity(req, env, pathParam(match[1]), pathParam(match[2])),
  },
  { method: "POST", pattern: /^\/admin\/tenants\/([^/]+)\/pending-live-activities\/([^/]+)\/delete\/?$/, handler: (req, env, match) =>
    admin.handleAdminDeletePendingLiveActivity(req, env, pathParam(match[1]), pathParam(match[2])),
  },
  { method: "POST", pattern: /^\/admin\/tenants\/([^/]+)\/start-tokens\/([^/]+)\/([^/]+)\/delete\/?$/, handler: (req, env, match) =>
    admin.handleAdminDeleteStartToken(req, env, pathParam(match[1]), pathParam(match[2]), pathParam(match[3])),
  },
  // Any signed-in person may connect a client to their own account, so this is
  // not an /admin route.
  { method: "GET", pattern: /^\/connect\/mcp\/authorize\/?$/, handler: (req, env) => mcpOAuth.handleAuthorize(req, env) },
  { method: "POST", pattern: /^\/connect\/mcp\/authorize\/?$/, handler: (req, env) =>
    mcpOAuth.handleAuthorizeDecision(req, env),
  },
  { method: "GET", pattern: /^\/admin\/?$/, handler: (req, env) => admin.handleAdminDashboard(req, env) },
];

/// A captured path segment, decoded. Route patterns capture the raw text, so
/// an id carrying anything that needs escaping used to be looked up in its
/// still-encoded form and never found: `GET /v1/cards/my%20card` searched for
/// the literal `my%20card`. A malformed escape is passed through rather than
/// throwing — the lookup 404s either way, and a 500 would be the wrong answer.
function pathParam(raw: string): string {
  try {
    return decodeURIComponent(raw);
  } catch {
    return raw;
  }
}

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
        // Costs nothing unless SUBSCRIPTION_REQUIRED is on and the scope is one
        // that is gated — no extra query on any other request.
        const lapsed = await subscription.subscriptionGate(env, auth, requiredScope);
        if (lapsed) return subscription.subscriptionRequiredResponse(lapsed);
        return await handler(req, env, auth, match, ctx);
      } catch (err) {
        if (err instanceof AuthRateLimitError) {
          return json({ error: err.message }, 429, { "retry-after": "60" });
        }
        if (err instanceof AuthError) return unauthorized(err.message);
        throw err;
      }
    },
  };
}

const handler: ExportedHandler<Env, WidgetReloadQueueMessage> = {
  async fetch(req, env, ctx) {
    const url = new URL(req.url);
    // RFC 9110: HEAD is GET without a body. Dispatch it against the GET routes
    // and let the HTTP layer drop the body — otherwise every endpoint 404s for
    // the uptime monitors and `curl -I` habits that reach for HEAD first.
    // Routes registered only for POST stay unreachable by HEAD, as they should.
    const method = req.method === "HEAD" ? "GET" : req.method;
    for (const route of routes) {
      if (route.method !== method) continue;
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
  async scheduled(_event, env, _ctx) {
    await sweepExpiredRateLimitBuckets(env);
  },
  async queue(batch: MessageBatch<WidgetReloadQueueMessage>, env, ctx) {
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
    maybeSweepRateLimitBuckets(env, ctx);
  },
};

// Reclaims rate limit buckets whose keys will never be touched again — a
// finished Live Activity's per-activity counter, a retired card's. Counters for
// live keys are collected in their own write batch; only the orphans need this.
//
// It rides the queue consumer because the account has no spare cron trigger
// (Workers Free allows 5). Two properties keep that from coupling maintenance to
// delivery: it runs after every message has been settled, and `waitUntil` keeps
// it off the path that returns the batch — a slow sweep must never hold acks
// long enough for messages to pass their visibility timeout and be redelivered,
// which would resend widget pushes. `sweepExpiredRateLimitBuckets` also
// swallows its own failures, so it cannot fail a batch.
//
// Sampled rather than run every time: buckets carry an `expires_at` two windows
// past their own, so reclaiming is never urgent, and a handful of sweeps a day
// is plenty at any volume this queue sees.
const RATE_LIMIT_SWEEP_PROBABILITY = 0.05;

function maybeSweepRateLimitBuckets(env: Env, ctx: ExecutionContext): void {
  if (Math.random() >= RATE_LIMIT_SWEEP_PROBABILITY) return;
  ctx.waitUntil(sweepExpiredRateLimitBuckets(env));
}

function preventSensitiveResponseCaching(pathname: string, response: Response): Response {
  const sensitive = pathname === "/v1"
    || pathname.startsWith("/v1/")
    || pathname === "/admin"
    || pathname.startsWith("/admin/")
    || pathname === "/mcp"
    || pathname === "/mcp/"
    || pathname.startsWith("/oauth/")
    || pathname.startsWith("/connect/")
    || pathname.startsWith("/login")
    || pathname.startsWith("/auth/");
  if (sensitive) {
    response.headers.set("cache-control", "no-store");
  }
  return response;
}

export default handler;
