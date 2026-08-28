// Shared HTML chrome for every signed-in web surface: the sign-in page, the MCP
// consent screen, and the admin dashboard. It lives outside all three because
// signing in must not depend on the dashboard — the dependency used to run that
// way round and made "admin" look like the only kind of web user there is.

export const WEB_HTML_SECURITY_HEADERS = {
  "content-security-policy": [
    "default-src 'none'",
    "base-uri 'none'",
    "form-action 'self'",
    "frame-ancestors 'none'",
    "object-src 'none'",
    "style-src 'unsafe-inline'",
  ].join("; "),
  // "same-origin", not "no-referrer". A referrer policy of no-referrer makes the
  // browser send `Origin: null` on a form POST — form submissions are
  // navigate-mode requests, and the Fetch standard folds the referrer policy
  // into how the Origin header is serialized for those — while also suppressing
  // Referer. Both signals the CSRF origin check reads therefore vanish, and
  // every form on these pages 403s with "Invalid request origin". `fetch()` is
  // immune (it defaults to CORS mode), which is why unit tests never saw it.
  // same-origin keeps Referer off every cross-origin navigation, so nothing
  // leaks to Apple or to an OAuth client, and preserves the Origin header we
  // actually depend on.
  "referrer-policy": "same-origin",
  "strict-transport-security": "max-age=31536000; includeSubDomains",
  "x-content-type-options": "nosniff",
} as const;

export function htmlResponse(body: string, status = 200): Response {
  return new Response(body, {
    status,
    headers: {
      "content-type": "text/html; charset=utf-8",
      ...WEB_HTML_SECURITY_HEADERS,
    },
  });
}

export function baseHTML(title: string, body: string): string {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(title)}</title>
<style>
  :root {
    color-scheme: light dark;
    --bg: #f8fbff;
    --fg: #06152a;
    --muted: #56657a;
    --line: #e2e7ee;
    --accent: #0968e8;
    --good: #11a789;
    --warn: #b86a00;
    --crit: #c62828;
    --offline: #98a2b3;
    --code-bg: #eef2f7;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #06152a;
      --fg: #f8fbff;
      --muted: #98a8c0;
      --line: #1a2b48;
      --accent: #22a8ff;
      --good: #24d6b5;
      --code-bg: #0c2340;
    }
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; padding: 24px; max-width: 1200px; margin: 0 auto;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
    background: var(--bg); color: var(--fg);
  }
  header { display: flex; align-items: baseline; justify-content: space-between; flex-wrap: wrap; gap: 12px; padding-bottom: 16px; border-bottom: 1px solid var(--line); margin-bottom: 24px; }
  header h1 { margin: 0; font-size: 22px; font-weight: 800; }
  .meta { color: var(--muted); font-size: 13px; }
  .meta a { color: var(--accent); }
  section { margin: 32px 0; }
  section h2 { font-size: 16px; font-weight: 700; margin: 0 0 12px; display: flex; align-items: baseline; gap: 8px; }
  .count { color: var(--muted); font-weight: 500; font-size: 13px; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th, td { text-align: left; padding: 8px 10px; border-bottom: 1px solid var(--line); vertical-align: top; }
  th { font-weight: 600; color: var(--muted); font-size: 11px; letter-spacing: .04em; text-transform: uppercase; }
  td.ts { color: var(--muted); white-space: nowrap; }
  code, pre { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
  code { background: var(--code-bg); padding: 1px 6px; border-radius: 4px; font-size: 12px; }
  pre { background: var(--code-bg); padding: 10px 12px; border-radius: 6px; overflow-x: auto; font-size: 11.5px; margin: 8px 0 0; }
  details summary { cursor: pointer; color: var(--accent); font-size: 12px; }
  .empty { color: var(--muted); font-size: 13px; }
  .error { color: var(--crit); }
  .tok { font-size: 11px; color: var(--muted); }
  .status { font-size: 11px; padding: 2px 8px; border-radius: 999px; background: var(--code-bg); color: var(--muted); }
  .status-good, .status-finished { color: var(--good); }
  .status-warning, .status-paused { color: var(--warn); }
  .status-critical { color: var(--crit); }
  .status-running { color: var(--accent); }
  .status-offline, .status-unknown { color: var(--offline); }
  .login { max-width: 420px; margin: 24px auto; }
  .login h2 { margin-bottom: 16px; }
  .login label { display: block; font-size: 12px; font-weight: 600; color: var(--muted); margin-bottom: 6px; text-transform: uppercase; letter-spacing: .04em; }
  .login input[type=password] { width: 100%; padding: 10px 12px; border-radius: 6px; border: 1px solid var(--line); background: var(--bg); color: var(--fg); font: inherit; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
  .button { display: inline-block; padding: 10px 18px; margin-top: 12px; border-radius: 6px; background: var(--accent); color: white; border: 0; font: inherit; font-weight: 600; cursor: pointer; text-decoration: none; }
  .button-secondary { background: transparent; color: var(--accent); border: 1px solid var(--line); }
  .button-small { padding: 5px 9px; margin: 0; font-size: 12px; }
  .button-danger { background: var(--crit); }
  .button-apple { background: var(--fg); color: var(--bg); display: block; text-align: center; }
  .api-token-form { display: flex; flex-direction: column; gap: 4px; }
  .api-token-form .button { align-self: stretch; text-align: center; }
  .api-key-form { display: grid; grid-template-columns: minmax(180px, 1fr) minmax(180px, 1fr) minmax(180px, 1fr) auto; gap: 12px; align-items: end; margin-bottom: 16px; }
  .api-key-form label { display: flex; flex-direction: column; gap: 6px; color: var(--muted); font-size: 12px; font-weight: 600; text-transform: uppercase; letter-spacing: .04em; }
  .api-key-form input, .api-key-form select { padding: 9px 10px; border-radius: 6px; border: 1px solid var(--line); background: var(--bg); color: var(--fg); font: inherit; text-transform: none; letter-spacing: normal; }
  @media (max-width: 780px) { .api-key-form { grid-template-columns: 1fr; } }
  .divider { display: flex; align-items: center; gap: 12px; margin: 20px 0; color: var(--muted); font-size: 12px; }
  .divider::before, .divider::after { content: ""; flex: 1; height: 1px; background: var(--line); }
  .muted { color: var(--muted); font-size: 12px; }
  .oauth-detail { display: grid; grid-template-columns: max-content minmax(0, 1fr); gap: 12px; align-items: start; padding: 8px 10px; border-bottom: 1px solid var(--line); font-size: 13px; }
  .oauth-detail-label { color: var(--muted); font-size: 11px; font-weight: 600; letter-spacing: .04em; text-transform: uppercase; }
  .oauth-detail code { display: block; min-width: 0; white-space: normal; overflow-wrap: anywhere; word-break: break-word; line-height: 1.45; }
  .actions { display: flex; justify-content: flex-end; gap: 8px; }
</style>
</head>
<body>
${body}
</body>
</html>`;
}

export function renderError(message: string): string {
  return baseHTML(
    "00Widget · Error",
    `<header><h1>00Widget</h1></header>
     <section><h2>Error</h2><p class="error">${esc(message)}</p>
     <p><a href="/login">try again</a></p></section>`,
  );
}

export function esc(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

export function enc(s: string): string {
  return encodeURIComponent(s);
}

// No `dec` counterpart to `enc`. Route captures are decoded once by
// `pathParam` in index.ts, which swallows a malformed escape rather than
// throwing; a second decode here corrupted ids containing a literal `%` and
// turned one into a 500. Anything that needs a decoded path segment already
// has one by the time a handler sees it.
