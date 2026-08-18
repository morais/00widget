import { llmsMarkdown } from "./generated/llmsDoc";
import { mcpConfigured } from "./mcpOAuth";
import type { Env } from "./types";

// Public, unauthenticated routes:
//   GET /              landing HTML — intro + agent prompt + link to docs
//   GET /llms.md       raw llms.md (for agents that fetch directly)
//   GET /llms.txt      short discovery doc pointing at /llms.md
//
// The agent prompt embedded below mirrors the README's
// "Pointing an agent at 00Widget from another project" block — keep them in
// sync when either changes. The README keeps `https://api.example.com` as a
// placeholder; the served copy substitutes the real request host.

// Built per request from the URL the Worker was actually reached on, so a fork
// or a staging deployment hands agents its own host instead of advertising
// whichever hostname happened to be hardcoded here.
function agentPrompt(baseURL: string): string {
  return `Integrate this project with 00Widget so its state shows up on iOS widgets and Live Activities.

Read the integration contract: ${baseURL}/llms.md
That single document is everything you need — don't pull in the rest of the 00Widget repo.

Operator-supplied env vars:
  00WIDGET_BASE_URL=${baseURL}
  00WIDGET_API_KEY=<bearer token>

Verify both work with \`curl $00WIDGET_BASE_URL/health\` and an authenticated \`GET /v1/cards\` before writing any code.

Then:
1. Identify the surfaces in this project that an iOS widget should reflect (status, build state, queue depth, in-progress jobs, etc.).
2. For each, pick a template (\`summary\`, \`progress\`, \`list\`, or \`action\`) per llms.md's decision matrix.
3. Add the smallest possible publish path — a single function that POSTs to /v1/cards/upsert with a stable \`id\`. No SDK, no class hierarchy.
4. If something is time-bounded with a clear end (a build, a charge cycle, a delivery), use a Live Activity instead of a card.

Constraints:
- Use a stable \`id\` per logical thing — never embed timestamps or run ids.
- Never put secrets or PII in card fields. They render on the Lock Screen.
- Always end Live Activities. Never make destructive actions auto-run from widgets.
- Don't publish more than ~once a minute per card unless the value actually changed.

If this project is itself a Cloudflare Worker, see the "Notes for Cloudflare Workers callers" section in llms.md — same-account integrations should use a Service Binding instead of a public HTTPS fetch.`;
}

export async function handleLanding(req: Request, env: Env): Promise<Response> {
  return new Response(renderLandingHTML(new URL(req.url).origin, mcpConfigured(env)), {
    status: 200,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "public, max-age=300",
      "content-security-policy": await landingContentSecurityPolicy(),
      "permissions-policy": "camera=(), geolocation=(), microphone=()",
      "referrer-policy": "no-referrer",
      // Sent from the HTML surfaces only. One response is enough for a browser
      // to pin the host, and it then covers /v1 too; non-browser API clients
      // ignore the header entirely.
      "strict-transport-security": "max-age=31536000; includeSubDomains",
      "x-content-type-options": "nosniff",
      "x-frame-options": "DENY",
    },
  });
}

// The landing page is public and cacheable, which rules out a per-request
// nonce: a shared cache would pin one nonce into the stored copy and hand it
// to every visitor for the life of the entry. The inline blocks are static, so
// hash them instead — the CSP stays correct no matter who serves the response.
let cachedCsp: string | null = null;

async function landingContentSecurityPolicy(): Promise<string> {
  if (cachedCsp) return cachedCsp;
  const [scriptHash, styleHash] = await Promise.all([
    sha256Base64(LANDING_SCRIPT),
    sha256Base64(LANDING_STYLES),
  ]);
  cachedCsp = [
    "default-src 'none'",
    "base-uri 'none'",
    "form-action 'none'",
    "frame-ancestors 'none'",
    "object-src 'none'",
    `script-src 'sha256-${scriptHash}'`,
    `style-src 'sha256-${styleHash}'`,
  ].join("; ");
  return cachedCsp;
}

export async function handleLlmsMd(req: Request): Promise<Response> {
  const baseURL = new URL(req.url).origin;
  return new Response(renderHostedLlmsMarkdown(baseURL), {
    status: 200,
    headers: {
      "content-type": "text/markdown; charset=utf-8",
      "cache-control": "public, max-age=300",
    },
  });
}

export function renderHostedLlmsMarkdown(baseURL: string): string {
  return llmsMarkdown
    .replace(
      "- Get two values from the operator: `00WIDGET_BASE_URL` and `00WIDGET_API_KEY`.",
      [
        `- Set \`00WIDGET_BASE_URL=${baseURL}\`; this hosted copy already knows the public Worker URL.`,
        "- Get `00WIDGET_API_KEY` from the operator.",
      ].join("\n"),
    )
    .replace(
      "- Verify `00WIDGET_BASE_URL` with `/health` and `00WIDGET_API_KEY` with `GET /v1/cards`.",
      `- Verify this Worker URL (\`${baseURL}\`) with \`/health\` and \`00WIDGET_API_KEY\` with \`GET /v1/cards\`.`,
    )
    .replace(
      "## Get the operator to give you\n\n| Env var              | Example                   | Where it comes from                |\n| -------------------- | ------------------------- | ---------------------------------- |\n| `00WIDGET_BASE_URL`  | `https://api.example.com` | The operator's deployed Worker URL |\n| `00WIDGET_API_KEY`   | a long random string      | A tenant API token generated by the operator |",
      `## Configure access\n\nThis hosted llms.md is being served by the 00Widget Worker you should call, so do not ask the operator for the base URL. Use:\n\n\`\`\`sh\n00WIDGET_BASE_URL=${baseURL}\n\`\`\`\n\nAsk the operator only for the API key:\n\n| Env var              | Example              | Where it comes from                         |\n| -------------------- | -------------------- | ------------------------------------------- |\n| \`00WIDGET_API_KEY\`   | a long random string | A tenant API token generated by the operator |`,
    )
    .replace(
      "Verify both before doing anything else:",
      "Verify the URL and API key before doing anything else:",
    );
}

export async function handleLlmsTxt(req: Request, env: Env): Promise<Response> {
  const baseURL = new URL(req.url).origin;
  const mcp = mcpConfigured(env)
    ? `
## MCP

An MCP server is available at ${baseURL}/mcp (Streamable HTTP, OAuth 2.1).
${baseURL}/mcp.json returns a client config for it. Agents writing code should
call the endpoints above directly instead.
`
    : "";
  const body = `# 00Widget

Widgets for all your agents.

A reusable iOS companion app and Cloudflare Worker backend that lets your web apps,
automations, and agents publish structured state to iOS widgets, Live Activities,
and the Dynamic Island.

## Integration contract for AI agents

The complete API contract is at ${baseURL}/llms.md — that one
document is everything an integrating agent needs.

## Endpoints worth knowing

- GET  /health                      health check
- POST /v1/cards/upsert              publish a dashboard card
- GET  /v1/cards                     list cards
- POST /v1/live-activities/start     queue/start a Live Activity
- POST /v1/live-activities/update    update one
- POST /v1/live-activities/end       end one

All /v1/* endpoints require Authorization: Bearer <api-token>. Tokens are issued
from the operator's /admin dashboard, not from this file.
${mcp}`;
  return new Response(body, {
    status: 200,
    headers: {
      "content-type": "text/plain; charset=utf-8",
      "cache-control": "public, max-age=300",
    },
  });
}

// ---------- HTML rendering ----------

// Kept verbatim as the exact bytes between <style> and </style>; the CSP
// hash is computed over this string, so any edit here changes the header too.
const LANDING_STYLES = `
  :root {
    color-scheme: light dark;
    --bg: #f8fbff;
    --fg: #06152a;
    --muted: #56657a;
    --line: #e2e7ee;
    --accent: #0968e8;
    --code-bg: #eef2f7;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #06152a;
      --fg: #f8fbff;
      --muted: #98a8c0;
      --line: #1a2b48;
      --accent: #22a8ff;
      --code-bg: #0c2340;
    }
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; padding: 32px 20px; max-width: 760px; margin: 0 auto;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
    line-height: 1.55; background: var(--bg); color: var(--fg);
  }
  header { margin-bottom: 24px; }
  h1 { font-size: 28px; font-weight: 800; margin: 0 0 4px; letter-spacing: -.01em; }
  .tagline { color: var(--muted); margin: 0 0 24px; font-size: 16px; }
  h2 { font-size: 18px; font-weight: 700; margin: 32px 0 12px; }
  p { margin: 0 0 12px; }
  a { color: var(--accent); }
  code, pre { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
  code { background: var(--code-bg); padding: 1px 6px; border-radius: 4px; font-size: 13px; }
  pre {
    background: var(--code-bg); padding: 16px; border-radius: 8px;
    overflow-x: auto; font-size: 12.5px; line-height: 1.5;
    border: 1px solid var(--line); white-space: pre-wrap; word-break: break-word;
  }
  pre code { background: transparent; padding: 0; font-size: inherit; }
  .copy-hint { color: var(--muted); font-size: 12px; margin-top: 8px; }
  .copy-wrap { position: relative; }
  .copy-btn {
    position: absolute; top: 10px; right: 10px;
    background: var(--bg); color: var(--fg);
    border: 1px solid var(--line); border-radius: 6px;
    padding: 4px 10px; font: inherit; font-size: 12px; cursor: pointer;
    opacity: .85;
  }
  .copy-btn:hover { opacity: 1; }
  .copy-btn[data-state="copied"] { color: var(--accent); border-color: var(--accent); }
  ul.endpoints { padding-left: 20px; margin: 0; }
  ul.endpoints li { margin: 4px 0; }
  footer { margin-top: 48px; padding-top: 16px; border-top: 1px solid var(--line); color: var(--muted); font-size: 12px; }
`;

// Same contract as LANDING_STYLES: the exact bytes between <script> and
// </script>, hashed into the CSP.
const LANDING_SCRIPT = `
  document.querySelectorAll("[data-copy-target]").forEach(function (btn) {
    btn.addEventListener("click", async function () {
      var id = btn.getAttribute("data-copy-target");
      var target = document.getElementById(id);
      if (!target) return;
      var text = target.innerText;
      var original = btn.textContent;
      try {
        await navigator.clipboard.writeText(text);
        btn.textContent = "Copied";
      } catch (_) {
        // Fallback for browsers without async clipboard support.
        var ta = document.createElement("textarea");
        ta.value = text;
        document.body.appendChild(ta);
        ta.select();
        try { document.execCommand("copy"); btn.textContent = "Copied"; }
        catch (__) { btn.textContent = "Copy failed"; }
        document.body.removeChild(ta);
      }
      btn.setAttribute("data-state", "copied");
      setTimeout(function () {
        btn.textContent = original;
        btn.removeAttribute("data-state");
      }, 1600);
    });
  });
`;

function renderLandingHTML(baseURL: string, mcpEnabled: boolean): string {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>00Widget — Widgets for all your agents</title>
<meta name="description" content="A reusable iOS companion app and Cloudflare Worker backend that lets your web apps, automations, and agents publish structured state to iOS widgets, Live Activities, and the Dynamic Island.">
<style>${LANDING_STYLES}</style>
</head>
<body>
<header>
  <h1>00Widget</h1>
  <p class="tagline">Widgets for all your agents.</p>
</header>

<p>A reusable iOS companion app and Cloudflare Worker backend that lets your web apps, automations, and agents publish structured state to iOS Home/Lock Screen widgets, Live Activities, and the Dynamic Island.</p>

<p>The server never sends UI — only structured state conforming to a small set of templates. The iOS app renders that state through predefined SwiftUI views.</p>

<h2>Pointing an agent at 00Widget from another project</h2>

<p>If you're inside another repo (a CI pipeline, a home-automation script, a server-side agent) and want Claude Code / Codex to publish state here, paste this into the agent — it's self-contained:</p>

<div class="copy-wrap">
  <button type="button" class="copy-btn" data-copy-target="agent-prompt" aria-label="Copy agent prompt">Copy</button>
  <pre id="agent-prompt"><code>${escapeHtml(agentPrompt(baseURL))}</code></pre>
</div>

<p class="copy-hint">The API contract is also available at <a href="/llms.md"><code>/llms.md</code></a>.</p>

${mcpEnabled ? mcpSection(baseURL) : ""}
<h2>API endpoints</h2>

<ul class="endpoints">
  <li><code>GET /health</code> — health check, no auth.</li>
  <li><code>POST /v1/cards/upsert</code> — publish a dashboard card.</li>
  <li><code>GET /v1/cards</code> — list cards for the API token.</li>
  <li><code>POST /v1/live-activities/start</code> / <code>update</code> / <code>end</code> — Live Activity lifecycle.</li>
  <li><code>POST /v1/actions/:id/run</code> — run an action by id.</li>
</ul>

<p>All <code>/v1/*</code> endpoints require <code>Authorization: Bearer &lt;api-token&gt;</code>. Tokens are issued from the operator's <a href="/admin"><code>/admin</code></a> dashboard.</p>

<footer>
  Source: <a href="https://github.com/morais/00widget">github.com/morais/00widget</a> · MIT
</footer>

<script>${LANDING_SCRIPT}</script>
</body>
</html>`;
}

// Only rendered where MCP is actually enabled. A deployment that has not turned
// it on should not advertise an endpoint that answers 404.
function mcpSection(baseURL: string): string {
  return `<h2>Connect an MCP client</h2>

<p>Hosts that speak the Model Context Protocol — ChatGPT connectors, Claude, some editors — can publish here without any code. Add this URL as a custom connector:</p>

<div class="copy-wrap">
  <button type="button" class="copy-btn" data-copy-target="mcp-url" aria-label="Copy MCP server URL">Copy</button>
  <pre id="mcp-url"><code>${escapeHtml(baseURL)}/mcp</code></pre>
</div>

<p class="copy-hint">The host will ask you to <a href="/login">sign in</a> with the Apple ID you use in the 00Widget app; approving mints an API token scoped to your account. For clients configured from a file rather than a URL, <a href="/mcp.json"><code>/mcp.json</code></a> is the same thing in config form.</p>
`;
}

async function sha256Base64(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  let binary = "";
  for (const byte of new Uint8Array(digest)) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}
