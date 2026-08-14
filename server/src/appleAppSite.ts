import type { Env } from "./types";
import { notFound } from "./http";

// Serves /.well-known/apple-app-site-association, the file iOS fetches to
// verify that this domain has authorised the app to claim its links.
//
// Verified 2026-08-14 against
// https://developer.apple.com/documentation/xcode/supporting-associated-domains
// Requirements that are easy to break and produce a silent failure — links keep
// opening in Safari with no error anywhere:
//   - served over HTTPS with no redirects (Apple does not follow them)
//   - content-type application/json
//   - no .json extension on the path, and not signed
//
// App IDs are `<TeamID>.<bundle id>` and are deployment-specific, so they come
// from wrangler [vars] rather than source: this repo is public and commits no
// real team or bundle identifiers.

// The single path prefix the app claims. Everything outside it keeps opening in
// the browser, which is deliberate rather than conservative: /admin/* is a web
// Sign in with Apple flow that breaks outright if iOS diverts it into the app,
// and /, /llms.md and /llms.txt exist to be read by humans and agents in a
// browser. Claiming "*" would capture all of them.
export const UNIVERSAL_LINK_PATH_PREFIX = "/app/";

interface AppleAppSiteAssociation {
  applinks: {
    details: Array<{
      appIDs: string[];
      components: Array<Record<string, string>>;
    }>;
  };
  appclips?: { apps: string[] };
}

export function buildAppleAppSiteAssociation(env: Env): AppleAppSiteAssociation | null {
  const appID = (env.APPLE_APP_ID ?? "").trim();
  if (!appID) return null;

  const association: AppleAppSiteAssociation = {
    applinks: {
      details: [
        {
          appIDs: [appID],
          components: [
            {
              "/": `${UNIVERSAL_LINK_PATH_PREFIX}*`,
              comment: "In-app links. Everything else stays in the browser.",
            },
          ],
        },
      ],
    },
  };

  // An App Clip's invocation URLs are claimed here too, under a separate key.
  // Unset until a clip target exists; keeping the shape here means enabling one
  // is a config change rather than another pass over Apple's CDN cache.
  const clipID = (env.APPLE_APP_CLIP_ID ?? "").trim();
  if (clipID) association.appclips = { apps: [clipID] };

  return association;
}

export async function handleAppleAppSiteAssociation(_req: Request, env: Env): Promise<Response> {
  const association = buildAppleAppSiteAssociation(env);
  // A deployment with no APPLE_APP_ID configured has no app to associate. 404
  // rather than serving an empty claim: an association listing no appIDs is a
  // valid document that positively tells iOS "no app handles this domain", and
  // Apple's CDN would cache that answer.
  if (!association) return notFound();

  return new Response(JSON.stringify(association), {
    status: 200,
    headers: {
      "content-type": "application/json",
      "x-content-type-options": "nosniff",
      // Apple's CDN fetches this, not the device. It changes only when the app
      // or clip identifiers change, which is close to never.
      "cache-control": "public, max-age=3600",
    },
  });
}
