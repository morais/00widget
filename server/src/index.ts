import type { Env } from "./types";
import { requireAuth, AuthError } from "./auth";
import { json, notFound, unauthorized } from "./http";
import * as cards from "./cards";
import * as devices from "./devices";
import * as widgets from "./widgets";
import * as liveActivities from "./liveActivities";
import * as actions from "./actions";

interface Route {
  method: string;
  pattern: RegExp;
  handler: (req: Request, env: Env, match: RegExpExecArray) => Promise<Response>;
}

const routes: Route[] = [
  {
    method: "GET",
    pattern: /^\/health\/?$/,
    handler: async () => json({ ok: true }),
  },
  authed("POST", /^\/v1\/cards\/upsert\/?$/, (req, env, auth) => cards.upsertCard(req, env, auth)),
  authed("GET", /^\/v1\/cards\/?$/, (req, env, auth) => cards.listCards(req, env, auth)),
  authed("GET", /^\/v1\/cards\/([^/]+)\/?$/, (req, env, auth, m) => cards.getCard(req, env, auth, m[1])),
  authed("DELETE", /^\/v1\/cards\/([^/]+)\/?$/, (req, env, auth, m) => cards.deleteCard(req, env, auth, m[1])),
  authed("POST", /^\/v1\/devices\/register\/?$/, (req, env, auth) => devices.registerDevice(req, env, auth)),
  authed("POST", /^\/v1\/widgets\/register-push-token\/?$/, (req, env, auth) =>
    widgets.registerWidgetPushToken(req, env, auth),
  ),
  authed("POST", /^\/v1\/live-activities\/register\/?$/, (req, env, auth) =>
    liveActivities.registerLiveActivity(req, env, auth),
  ),
  authed("POST", /^\/v1\/live-activities\/register-start-token\/?$/, (req, env, auth) =>
    liveActivities.registerLiveActivityStartToken(req, env, auth),
  ),
  authed("POST", /^\/v1\/live-activities\/start\/?$/, (req, env, auth) =>
    liveActivities.startLiveActivity(req, env, auth),
  ),
  authed("GET", /^\/v1\/live-activities\/pending\/?$/, (req, env, auth) =>
    liveActivities.pendingActivities(req, env, auth),
  ),
  authed("POST", /^\/v1\/live-activities\/update\/?$/, (req, env, auth) =>
    liveActivities.updateLiveActivity(req, env, auth),
  ),
  authed("POST", /^\/v1\/live-activities\/end\/?$/, (req, env, auth) =>
    liveActivities.endLiveActivity(req, env, auth),
  ),
  authed("POST", /^\/v1\/actions\/([^/]+)\/run\/?$/, (req, env, auth, m) =>
    actions.runAction(req, env, auth, m[1]),
  ),
];

type AuthedHandler = (
  req: Request,
  env: Env,
  auth: import("./auth").AuthContext,
  match: RegExpExecArray,
) => Promise<Response>;

function authed(method: string, pattern: RegExp, handler: AuthedHandler): Route {
  return {
    method,
    pattern,
    handler: async (req, env, match) => {
      try {
        const auth = await requireAuth(req, env);
        return await handler(req, env, auth, match);
      } catch (err) {
        if (err instanceof AuthError) return unauthorized(err.message);
        throw err;
      }
    },
  };
}

const handler: ExportedHandler<Env> = {
  async fetch(req, env) {
    const url = new URL(req.url);
    for (const route of routes) {
      if (route.method !== req.method) continue;
      const match = route.pattern.exec(url.pathname);
      if (!match) continue;
      try {
        return await route.handler(req, env, match);
      } catch (err) {
        console.error("handler error", err);
        return json({ error: "internal error" }, 500);
      }
    }
    return notFound();
  },
};

export default handler;
