# Security policy

## Reporting a vulnerability

Please report security issues **privately**, not through public GitHub issues.

Email **morais.pedro@gmail.com** with:

- A description of the issue and its impact
- Steps to reproduce (or a proof-of-concept)
- The affected component (`server/`, `ios/`, or specific files)
- Whether you'd like to be credited in the fix announcement

You'll get an acknowledgement within 3 working days. We aim to ship a fix or
mitigation within 30 days for high-severity issues; coordinated disclosure
timelines are negotiable.

## Scope

In scope:

- The Cloudflare Worker under `server/` (HTTP API, admin dashboard,
  authentication, rate limiting, tenant isolation, APNs interactions)
- The iOS app and widget extension under `ios/` (Keychain handling, App Group
  storage, App Intents, push handling)
- The data-model contract between the two (`server/src/types.ts` and
  `ios/Sources/Shared/Models/`)

Out of scope:

- The hosted deployment at `api.00widget.com` — that's the public Worker; if
  you find a bug in the *code* it still applies, but please don't run
  destructive or noisy probes against the live host.
- Bugs in upstream dependencies (zod, Wrangler, Cloudflare Workers, Apple's
  ActivityKit / WidgetKit / APNs). Report those upstream.
- Issues that require physical access to an unlocked device, or that depend on
  the user installing a malicious profile / sideloaded build.
- Social-engineering an admin into adding an attacker's email to
  `ADMIN_EMAILS`.

## Known constraints (operator's responsibility)

Some defaults and toggles affect security posture. Operators deploying this
project should be aware:

- **`ADMIN_API_TOKEN_LOGIN=true`** turns *any* value in `API_KEYS` into a full
  admin credential (create/revoke API keys for any tenant, delete any tenant's
  data). It is **off by default** and gated behind a per-IP rate limit (10
  attempts / hour). Enable only as a fallback and use a strong random token.
- **`APPLE_APP_LOGIN_ENABLED=true`** opens self-service tenant signup to
  anyone with a verified Apple ID. It is **off by default**. When enabled the
  endpoint requires a nonce (validated against the id_token's `nonce` claim)
  and is rate-limited per Apple `sub` at 30 / hour.
- **`SHARING_ENABLED`** controls cross-tenant share fanout. Sharing by
  `activity_kind` is coarse-grained: accepting a share for kind `progress`
  exposes *all* of the owner's current and future `progress` Live Activities
  to the recipient. Disable if your tenants shouldn't be able to fan out to
  each other.
- The APNs `.p8` private key lives only as a Wrangler secret on the backend.
  Never put it on-device, in `wrangler.toml`, or in the repo.
- Cloudflare observability logs (`[observability] enabled = true`) capture
  request errors and APNs reason strings (no full push tokens). Treat the
  Cloudflare dashboard as sensitive.

## Things that look bad but aren't

- The `git` history shows files named `.dev.vars.example`, `wrangler.toml.sample`,
  and `project.yml.sample` containing placeholders like `dev-key-1` and
  `REPLACE_WITH_D1_DATABASE_ID`. These are intentional templates; the real
  `.dev.vars`, `wrangler.toml`, and `project.yml` are gitignored.
- The webhook integration accepts only `https://` URLs and rejects literal
  private/loopback/link-local IPs (see `isBlockedWebhookHostname` in
  `server/src/types.ts`). The check is hostname-based by design; on
  Cloudflare Workers the runtime has no private-network reachability.

## Defensive properties this project tries to maintain

If you find a way to break any of these, please report it:

1. **Tenant isolation.** Every read/write through `server/src/storage.ts` is
   scoped by `tenant_id`. No `/v1/*` endpoint should return another tenant's
   data, and no admin action on tenant A should mutate tenant B.
2. **API key opacity.** API keys are stored only as SHA-256 hashes. The plain
   token is shown exactly once at creation time.
3. **Apple id_token validation.** All flows verify the RS256 signature against
   Apple's JWKS, `iss == https://appleid.apple.com`, `aud` matches the
   configured client id, `exp` is in the future, and `nonce` matches the
   expected value (when supplied).
4. **CSRF protection.** Every state-changing admin endpoint requires a
   per-session CSRF token, validated in constant time, plus a same-origin
   Origin/Referer check.
5. **No remote-controlled UI.** The server only sends structured state. The
   iOS app/widget renders it through predefined SwiftUI views. There is no
   server-pushed HTML, no JavaScript-on-device, no dynamic code loading.
6. **Destructive-action guard.** App Intents triggered from widgets refuse
   to run actions with `role: destructive` or `confirm: true`, both on the
   client (`RunDashboardActionIntent`) and on the server (`actions.ts
   isSafeFromWidget`). Either side rejecting is sufficient.
7. **Bounded inputs.** Every endpoint enforces a request-body byte cap, zod
   validates field lengths, and rate limits cap write throughput per tenant
   and per resource.

## Acknowledgements

Researchers who report valid issues will be credited in the release notes
unless they ask otherwise.
