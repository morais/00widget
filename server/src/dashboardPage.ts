import { loadDashboard } from "./dashboard";
import { WEB_PREVIEW_RENDERER, WEB_PREVIEW_STYLES, sha256Base64 } from "./guestPage";
import { baseHTML, esc } from "./html";
import type { Env } from "./types";
import {
  redirectToSignIn,
  requireWebSession,
  resolveWebTenantIdentity,
  type WebPrincipal,
} from "./webSession";

// The signed-in owner's own dashboard in a browser. The session only names an
// identity; the tenant is re-resolved from it on every request, exactly as the
// MCP consent screen does, and never read from the URL — so there is no way
// to point this page at another account, administrators included.
//
// The data is rendered into the page rather than fetched by it. That keeps
// /v1 bearer-only (a cookie never authenticates an API call), lets the CSP
// forbid every connection, and makes Refresh a plain link: one page load, two
// D1 reads, no writes. There is deliberately no polling and no rate limit — a
// limiter bucket is a D1 write, which would cost far more than the reads it
// guards.

const DASHBOARD_STYLES = `
main{max-width:72rem}
.toolbar{display:flex;align-items:baseline;justify-content:space-between;flex-wrap:wrap;gap:.5rem 1rem;margin:0 0 1.25rem}
.toolbar h1{margin:0}
.toolbar nav{display:flex;align-items:baseline;gap:1rem;font-size:.9rem;color:var(--muted)}
.toolbar a{color:var(--accent);text-decoration:none;font-weight:600}
.msg{color:var(--muted)}
`.trim();

const DASHBOARD_BOOT = `
(function(){
  var P=globalThis.ZeroZeroPreview;
  var out=document.getElementById('out');
  var stamp=document.getElementById('stamp');
  var d=JSON.parse(document.getElementById('data').textContent);
  out.innerHTML=P.renderDashboard(d);
  stamp.textContent='Updated '+new Date(d.generatedAt).toLocaleTimeString();
})();
`.trim();

let cachedCsp: string | null = null;

async function dashboardContentSecurityPolicy(): Promise<string> {
  if (cachedCsp) return cachedCsp;
  const [rendererHash, bootHash, previewStyleHash, pageStyleHash] = await Promise.all([
    sha256Base64(WEB_PREVIEW_RENDERER),
    sha256Base64(DASHBOARD_BOOT),
    sha256Base64(WEB_PREVIEW_STYLES),
    sha256Base64(DASHBOARD_STYLES),
  ]);
  // The JSON data block is not executed, so script-src does not govern it;
  // connect-src 'none' holds because this page never makes a request.
  cachedCsp = [
    "default-src 'none'",
    `style-src 'sha256-${previewStyleHash}' 'sha256-${pageStyleHash}'`,
    `script-src 'sha256-${rendererHash}' 'sha256-${bootHash}'`,
    "connect-src 'none'",
    "base-uri 'none'",
    "form-action 'none'",
    "frame-ancestors 'none'",
  ].join("; ");
  return cachedCsp;
}

/// JSON inside a <script> element ends at the first `</script`, whatever the
/// JSON meant — so a card titled `</script><script>…` would otherwise be
/// markup. Escaping `<`, `>` and `&` as \u sequences leaves the value
/// unchanged for JSON.parse and gives the HTML parser nothing to act on.
/// U+2028/2029 are escaped for the same reason in older JS engines.
export function jsonForScriptBlock(value: unknown): string {
  return JSON.stringify(value)
    .replace(/</g, "\\u003c")
    .replace(/>/g, "\\u003e")
    .replace(/&/g, "\\u0026")
    .replace(/\u2028/g, "\\u2028")
    .replace(/\u2029/g, "\\u2029");
}

function renderDashboardHTML(email: string, data: unknown): string {
  return `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<title>Dashboard — 00Widget</title>
<style>${WEB_PREVIEW_STYLES}</style>
<style>${DASHBOARD_STYLES}</style>
</head><body><main>
<div class="toolbar"><h1>00Widget</h1><nav><span id="stamp"></span><a href="/dashboard">Refresh</a><a href="/logout">Sign out</a></nav></div>
<p class="producer">${esc(email)}</p>
<div id="out"><p class="msg">Loading…</p></div>
</main><script type="application/json" id="data">${jsonForScriptBlock(data)}</script><script>${WEB_PREVIEW_RENDERER}</script><script>${DASHBOARD_BOOT}</script></body></html>`;
}

function renderNoAccount(session: WebPrincipal): string {
  const body = session.isAdmin
    ? `<p>${esc(session.email)} is an administrator session with no account of its own.
       Use <a href="/admin">the admin dashboard</a> to look at an account.</p>`
    : `<p>${esc(session.email)} does not own a 00Widget account yet. Sign in to the iOS app
       with this Apple ID first, then come back.</p>`;
  return baseHTML(
    "00Widget · Dashboard",
    `<header><h1>00Widget · Dashboard</h1><span class="meta"><a href="/logout">Sign out</a></span></header>
     <section><h2>No dashboard to show</h2>${body}</section>`,
  );
}

const PAGE_HEADERS = {
  "content-type": "text/html; charset=utf-8",
  "cache-control": "no-store",
  "permissions-policy": "camera=(), geolocation=(), microphone=()",
  // A card's deep link leaves this origin; its target does not need to know
  // it was reached from someone's dashboard.
  "referrer-policy": "no-referrer",
  "strict-transport-security": "max-age=31536000; includeSubDomains",
  "x-content-type-options": "nosniff",
  "x-frame-options": "DENY",
} as const;

export async function handleDashboardPage(req: Request, env: Env): Promise<Response> {
  const session = await requireWebSession(req, env);
  if (!session) return redirectToSignIn(req);

  const identity = await resolveWebTenantIdentity(env, session);
  if (!identity) {
    return new Response(renderNoAccount(session), {
      status: 409,
      headers: { ...PAGE_HEADERS, "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'" },
    });
  }

  const dashboard = await loadDashboard(env, identity.tenantId);
  const data = { ...dashboard, generatedAt: new Date().toISOString() };
  return new Response(renderDashboardHTML(session.email, data), {
    status: 200,
    headers: { ...PAGE_HEADERS, "content-security-policy": await dashboardContentSecurityPolicy() },
  });
}
