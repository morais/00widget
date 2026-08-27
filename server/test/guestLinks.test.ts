import { describe, it, expect } from "vitest";
import handler from "../src/index";
import { makeEnv, authedRequest, seedApiKey, testApiKey } from "./helpers";
import * as storage from "../src/storage";
import { sha256Hex, ApiScopePresets } from "../src/auth";
import { DashboardCardInputSchema, GuestLinkTtl } from "../src/types";
import { MAX_LIVE_GUEST_LINKS } from "../src/guestLinks";

const ctx = {} as ExecutionContext;
const TENANT = "tenant-owner";
const OWNER_KEY = "owner-key";

type Env = ReturnType<typeof makeEnv>;

const fetch = (req: Request, env: Env) =>
  (handler.fetch as any)(req, env, ctx) as Promise<Response>;

async function ownerEnv(scopes = ApiScopePresets.appOnly, sessionId = "session-1"): Promise<Env> {
  const env = makeEnv();
  await seedApiKey(env, OWNER_KEY, TENANT, "app", sessionId, "", "2099-01-01T00:00:00.000Z", scopes);
  return env;
}

async function seedCard(env: Env, id = "washer") {
  await storage.putCard(env, TENANT, await sha256Hex(testApiKey(OWNER_KEY)), {
    id,
    template: "progress",
    title: "Washer",
    value: "42",
    status: "running",
    actions: [{ id: "stop", label: "Stop", role: "normal", confirm: false, payload: { s: "x" } }],
  });
}

async function seedActivity(env: Env, instanceId = "activity-1") {
  await storage.putActivityInstance(env, TENANT, await sha256Hex(testApiKey(OWNER_KEY)), {
    activityInstanceId: instanceId,
    externalActivityId: "washer-cycle",
    kind: "appliance",
    title: "Washer cycle",
    state: "running",
    updatedAt: new Date().toISOString(),
  });
  await storage.putActivityTarget(env, instanceId, TENANT, TENANT);
}

function mint(env: Env, body: unknown, key = OWNER_KEY) {
  return fetch(
    authedRequest("https://x/v1/shares/guest", { method: "POST", body: JSON.stringify(body) }, key),
    env,
  );
}

/// Authenticated as the owner. The default key in `authedRequest` belongs to
/// another tenant, so passing it here would silently test isolation instead.
function asOwner(env: Env, path: string, init: RequestInit = {}) {
  return fetch(authedRequest(`https://x${path}`, init, OWNER_KEY), env);
}

function asGuest(env: Env, token: string, path = "/v1/guest/resource", init: RequestInit = {}) {
  return fetch(authedRequest(`https://x${path}`, init, token), env);
}

describe("guest links — minting", () => {
  it("mints a link for a card the caller owns", async () => {
    const env = await ownerEnv();
    await seedCard(env);
    const res = await mint(env, { resourceKind: "card", resourceId: "washer" });
    expect(res.status).toBe(201);
    const body = (await res.json()) as any;
    expect(body.token).toMatch(/^zwg_/);
    expect(body.resourceKind).toBe("card");
    expect(body.resourceId).toBe("washer");
  });

  it("puts the token in the URL fragment, never the path", async () => {
    // The whole point of the fragment: a bearer token in the path would be
    // written to Cloudflare's request logs on every open.
    const env = await ownerEnv();
    await seedCard(env);
    const body = (await (await mint(env, { resourceKind: "card", resourceId: "washer" })).json()) as any;
    expect(body.url).toBe(`https://x/app/g#${body.token}`);
    const url = new URL(body.url);
    expect(url.pathname).toBe("/app/g");
    expect(url.pathname).not.toContain(body.token);
    expect(url.search).toBe("");
    expect(url.hash).toBe(`#${body.token}`);
  });

  it("refuses to mint for a resource that does not exist", async () => {
    const env = await ownerEnv();
    const res = await mint(env, { resourceKind: "card", resourceId: "nope" });
    expect(res.status).toBe(404);
  });

  it("refuses to mint for another tenant's card", async () => {
    const env = await ownerEnv();
    await storage.putCard(env, "someone-else", "other-hash", {
      id: "theirs", template: "summary", title: "Theirs", status: "good",
    });
    const res = await mint(env, { resourceKind: "card", resourceId: "theirs" });
    expect(res.status).toBe(404);
  });

  it("requires shares:manage", async () => {
    const env = await ownerEnv(ApiScopePresets.readOnly);
    await seedCard(env);
    const res = await mint(env, { resourceKind: "card", resourceId: "washer" });
    expect(res.status).toBe(403);
  });

  it("rejects a resource kind that names a class of activities", async () => {
    // Guest links are per instance. "activity_kind" is the shares table's
    // coarse form and must not be reachable here.
    const env = await ownerEnv();
    const res = await mint(env, { resourceKind: "activity_kind", resourceId: "progress" });
    expect(res.status).toBe(400);
  });
});

describe("guest links — expiry", () => {
  it("caps an activity link at the 12 hours a Live Activity can survive", async () => {
    const env = await ownerEnv();
    await seedActivity(env);
    const body = (await (await mint(env, {
      resourceKind: "activity",
      resourceId: "activity-1",
      ttlSeconds: 30 * 24 * 60 * 60,
    })).json()) as any;
    const ttl = Date.parse(body.expiresAt) - Date.now();
    expect(ttl).toBeLessThanOrEqual(GuestLinkTtl.activityMaxSeconds * 1000 + 1000);
    expect(ttl).toBeGreaterThan(GuestLinkTtl.activityMaxSeconds * 1000 - 60_000);
  });

  it("caps a card link at the card maximum", async () => {
    const env = await ownerEnv();
    await seedCard(env);
    const body = (await (await mint(env, {
      resourceKind: "card",
      resourceId: "washer",
      ttlSeconds: 365 * 24 * 60 * 60,
    })).json()) as any;
    const ttl = Date.parse(body.expiresAt) - Date.now();
    expect(ttl).toBeLessThanOrEqual(GuestLinkTtl.cardMaxSeconds * 1000 + 1000);
  });

  it("does not extend the deadline when the link is used", async () => {
    // Sliding expiry on a credential printed on a QR code would let anyone
    // holding it keep the link alive forever just by opening it.
    const env = await ownerEnv();
    await seedCard(env);
    const body = (await (await mint(env, { resourceKind: "card", resourceId: "washer" })).json()) as any;
    for (let i = 0; i < 3; i++) expect((await asGuest(env, body.token)).status).toBe(200);
    const links = (await (await asOwner(env, "/v1/shares/guest")).json()) as any;
    expect(links.links[0].expiresAt).toBe(body.expiresAt);
  });
});

describe("guest links — what a guest can reach", () => {
  it("reads the bound card, with actions stripped", async () => {
    const env = await ownerEnv();
    await seedCard(env);
    const body = (await (await mint(env, { resourceKind: "card", resourceId: "washer" })).json()) as any;
    const res = await asGuest(env, body.token);
    expect(res.status).toBe(200);
    const payload = (await res.json()) as any;
    expect(payload.card.title).toBe("Washer");
    // View-only: a shared card must not advertise buttons that would 403, and
    // must never carry the private action payload.
    expect(payload.card.actions).toBeUndefined();
    expect(JSON.stringify(payload)).not.toContain("owner-only");
  });

  it("reads the bound activity", async () => {
    const env = await ownerEnv();
    await seedActivity(env);
    const body = (await (await mint(env, { resourceKind: "activity", resourceId: "activity-1" })).json()) as any;
    const payload = (await (await asGuest(env, body.token)).json()) as any;
    expect(payload.resourceKind).toBe("activity");
    expect(payload.activity.title).toBe("Washer cycle");
  });

  it("cannot reach anything else in the API", async () => {
    const env = await ownerEnv();
    await seedCard(env);
    const body = (await (await mint(env, { resourceKind: "card", resourceId: "washer" })).json()) as any;
    // Every one of these needs a scope the guest preset does not contain, so
    // the existing scope check is the whole enforcement.
    for (const [method, path] of [
      ["GET", "/v1/cards"],
      ["GET", "/v1/cards/washer"],
      ["GET", "/v1/dashboard"],
      ["GET", "/v1/live-activities"],
      ["POST", "/v1/cards/upsert"],
      ["POST", "/v1/actions/stop/run"],
      ["POST", "/v1/shares/guest"],
      ["GET", "/v1/shares/guest"],
    ] as const) {
      const res = await asGuest(env, body.token, path, {
        method,
        ...(method === "POST" ? { body: "{}" } : {}),
      });
      expect(res.status, `${method} ${path}`).toBe(403);
    }
  });

  it("cannot register a push token for an activity it is not bound to", async () => {
    const env = await ownerEnv();
    await seedCard(env);
    await seedActivity(env);
    const body = (await (await mint(env, { resourceKind: "card", resourceId: "washer" })).json()) as any;
    const res = await asGuest(env, body.token, "/v1/guest/live-activities/register", {
      method: "POST",
      body: JSON.stringify({ deviceId: "d1", localActivityId: "l1", pushToken: "ab12" }),
    });
    expect(res.status).toBe(400);
  });

  it("registers a push token for the activity it is bound to", async () => {
    const env = await ownerEnv();
    await seedActivity(env);
    const body = (await (await mint(env, { resourceKind: "activity", resourceId: "activity-1" })).json()) as any;
    const res = await asGuest(env, body.token, "/v1/guest/live-activities/register", {
      method: "POST",
      body: JSON.stringify({ deviceId: "guest-device", localActivityId: "local-1", pushToken: "ab12cd" }),
    });
    expect(res.status).toBe(200);
    const deliveries = await storage.listActivityDeliveries(env, "activity-1");
    expect(deliveries.map((d) => d.record.pushToken)).toContain("ab12cd");
  });

  it("rejects a non-hex push token", async () => {
    const env = await ownerEnv();
    await seedActivity(env);
    const body = (await (await mint(env, { resourceKind: "activity", resourceId: "activity-1" })).json()) as any;
    const res = await asGuest(env, body.token, "/v1/guest/live-activities/register", {
      method: "POST",
      body: JSON.stringify({ deviceId: "d", localActivityId: "l", pushToken: "not-hex!" }),
    });
    expect(res.status).toBe(400);
  });
});

describe("guest links — listing and revocation", () => {
  it("lists links without ever returning their tokens", async () => {
    const env = await ownerEnv();
    await seedCard(env);
    const minted = (await (await mint(env, { resourceKind: "card", resourceId: "washer" })).json()) as any;
    const res = await asOwner(env, "/v1/shares/guest");
    expect(res.status).toBe(200);
    const body = await res.text();
    expect(body).toContain(minted.id);
    expect(body).not.toContain(minted.token);
  });

  it("revoking a link kills it immediately", async () => {
    const env = await ownerEnv();
    await seedCard(env);
    const minted = (await (await mint(env, { resourceKind: "card", resourceId: "washer" })).json()) as any;
    expect((await asGuest(env, minted.token)).status).toBe(200);

    const del = await asOwner(env, `/v1/shares/guest/${minted.id}`, { method: "DELETE" });
    expect(del.status).toBe(200);
    expect((await asGuest(env, minted.token)).status).toBe(401);
  });

  it("cannot revoke another tenant's link", async () => {
    const env = await ownerEnv();
    await seedCard(env);
    const minted = (await (await mint(env, { resourceKind: "card", resourceId: "washer" })).json()) as any;
    await seedApiKey(env, "other-key", "tenant-other", "app", "session-other", "",
      "2099-01-01T00:00:00.000Z", ApiScopePresets.appOnly);
    const del = await fetch(
      authedRequest(`https://x/v1/shares/guest/${minted.id}`, { method: "DELETE" }, "other-key"),
      env,
    );
    expect(del.status).toBe(404);
    // …and the link still works for its owner, so a probe changes nothing.
    expect((await asGuest(env, minted.token)).status).toBe(200);
  });

  it("keeps account-level guest links alive when one device signs out", async () => {
    const env = await ownerEnv();
    await seedCard(env);
    await seedActivity(env);
    const cardLink = (await (await mint(env, { resourceKind: "card", resourceId: "washer" })).json()) as any;
    const activityLink = (await (await mint(env, { resourceKind: "activity", resourceId: "activity-1" })).json()) as any;
    expect((await asGuest(env, cardLink.token)).status).toBe(200);

    const signOut = await asOwner(env, "/v1/auth/token", { method: "DELETE" });
    expect(signOut.status).toBe(200);

    expect((await asGuest(env, cardLink.token)).status).toBe(200);
    expect((await asGuest(env, activityLink.token)).status).toBe(200);
  });
});

describe("guest links — abuse limits", () => {
  it("spends the share budget, not the registration budget", async () => {
    // Minting used to burn registrationTenantDay, which device, widget and
    // Live Activity registration also draw on — so handing out links could
    // lock a tenant out of registering its own hardware.
    const env = await ownerEnv(ApiScopePresets.legacyPublisher);
    await seedCard(env);
    for (let i = 0; i < 3; i++) {
      expect((await mint(env, { resourceKind: "card", resourceId: "washer" })).status).toBe(201);
    }
    const register = await asOwner(env, "/v1/devices/register", {
      method: "POST",
      body: JSON.stringify({ deviceId: "d1", appVersion: "1.0", platform: "ios" }),
    });
    expect(register.status).not.toBe(429);
  });

  it("caps the number of links standing at once", async () => {
    // Two limits at different timescales, and the standing cap is the one that
    // survives a patient attacker: shareTenantDay (120) bounds a single day, so
    // reaching 200 live links takes more than one — seed them rather than
    // minting through a limit deliberately set lower.
    const env = await ownerEnv();
    await seedCard(env);
    (env.ZW_DB as any).seedGuestKeys(TENANT, MAX_LIVE_GUEST_LINKS);
    const res = await mint(env, { resourceKind: "card", resourceId: "washer" });
    expect(res.status).toBe(429);
    expect(await res.text()).toContain("too many active guest links");
  });

  it("still mints when the standing total is one below the cap", async () => {
    const env = await ownerEnv();
    await seedCard(env);
    (env.ZW_DB as any).seedGuestKeys(TENANT, MAX_LIVE_GUEST_LINKS - 1);
    expect((await mint(env, { resourceKind: "card", resourceId: "washer" })).status).toBe(201);
  });

  it("charges a guest's registration to the guest, never the owner", async () => {
    // A QR code is a bearer token with no per-person identity. If a guest's
    // registration drew on the owner's budget, one widely-shown code would
    // exhaust it and take the owner's own registrations down with it.
    const env = await ownerEnv();
    await seedActivity(env);
    const link = (await (await mint(env, { resourceKind: "activity", resourceId: "activity-1" })).json()) as any;
    for (let i = 0; i < 5; i++) {
      const res = await asGuest(env, link.token, "/v1/guest/live-activities/register", {
        method: "POST",
        body: JSON.stringify({ deviceId: `d${i}`, localActivityId: `l${i}`, pushToken: "abcd" }),
      });
      expect(res.status).toBe(200);
    }
    const ownerWrite = await asOwner(env, "/v1/devices/register", {
      method: "POST",
      body: JSON.stringify({ deviceId: "owner-device", appVersion: "1.0", platform: "ios" }),
    });
    expect(ownerWrite.status).not.toBe(429);
  });

  it("prunes guest credentials that lapsed over a day ago", async () => {
    const env = await ownerEnv();
    await seedCard(env);
    const stale = (await (await mint(env, { resourceKind: "card", resourceId: "washer" })).json()) as any;
    // Backdate it past the grace period, then mint again to trigger the sweep.
    const db = env.ZW_DB as any;
    db.expireApiKey(stale.id, "2020-01-01T00:00:00.000Z");
    expect((await mint(env, { resourceKind: "card", resourceId: "washer" })).status).toBe(201);
    // Gone entirely, not merely filtered out of the listing.
    expect((await asGuest(env, stale.token)).status).toBe(401);
    const links = (await (await asOwner(env, "/v1/shares/guest")).json()) as any;
    expect(links.links.some((l: any) => l.id === stale.id)).toBe(false);
  });
});

describe("guest link browser page", () => {
  it("serves HTML that never receives the token server-side", async () => {
    const res = await fetch(new Request("https://x/app/g"), makeEnv());
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")?.startsWith("text/html")).toBe(true);
    const body = await res.text();
    // The page is identical for everyone; the token is read from location.hash.
    expect(body).toContain("location.hash");
    expect(body).toContain("/v1/guest/resource");
  });

  it("is locked down by CSP with hashes matching the inline blocks", async () => {
    const res = await fetch(new Request("https://x/app/g"), makeEnv());
    const csp = res.headers.get("content-security-policy") ?? "";
    const body = await res.text();

    const sha256Base64 = async (input: string) => {
      const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
      return btoa(String.fromCharCode(...new Uint8Array(digest)));
    };
    const style = /<style>([\s\S]*?)<\/style>/.exec(body)?.[1];
    const script = /<script>([\s\S]*?)<\/script>/.exec(body)?.[1];
    expect(csp).toContain(`style-src 'sha256-${await sha256Base64(style!)}'`);
    expect(csp).toContain(`script-src 'sha256-${await sha256Base64(script!)}'`);
    // The token lives in the DOM, so the page must not be able to send it
    // anywhere but back to this origin.
    expect(csp).toContain("connect-src 'self'");
    expect(csp).toContain("default-src 'none'");
    expect(csp).not.toContain("'unsafe-inline'");
    expect(res.headers.get("referrer-policy")).toBe("no-referrer");
  });

  it("draws a progress bar, matching how the device reads the fraction", async () => {
    const res = await fetch(new Request("https://x/app/g"), makeEnv());
    const body = await res.text();
    const script = /<script>([\s\S]*?)<\/script>/.exec(body)?.[1] ?? "";
    expect(script).toContain("var progressBar=function");
    expect(body).toContain(".prog rect.fill{");

    // Run the page's own fraction logic against the cases that separate it
    // from a naive parse. It has to agree with DashboardCard.progressValue on
    // the device, or the same shared card reads differently in a browser.
    const source = /var clamp01=[\s\S]*?return isFinite\(d\)\?clamp01\(d>1\?d\/100:d\):null;\n {2}\};/
      .exec(script)?.[0];
    expect(source).toBeTruthy();
    const fraction = new Function(`${source} return fraction;`)() as (
      card: Record<string, unknown>,
    ) => number | null;

    // An explicit progress wins on any template.
    expect(fraction({ template: "progress", value: "184 of 240", progress: 0.767 })).toBe(0.767);
    expect(fraction({ template: "summary", progress: 0.25 })).toBe(0.25);
    expect(fraction({ template: "progress", progress: 1.4 })).toBe(1);
    // The legacy fallback: value as the fraction, above 1 read as a percentage.
    expect(fraction({ template: "progress", value: "0.5" })).toBe(0.5);
    expect(fraction({ template: "progress", value: "50" })).toBe(0.5);
    expect(fraction({ template: "progress", value: "2" })).toBe(0.02);
    // And what must NOT be parsed: Swift's Double(_:) rejects a string that is
    // not wholly a number, so parseFloat would have drawn 1.84% here.
    expect(fraction({ template: "progress", value: "184 of 240" })).toBeNull();
    expect(fraction({ template: "progress", value: "" })).toBeNull();
    expect(fraction({ template: "summary", value: "3.2" })).toBeNull();
  });

  it("renders a shared Live Activity's state, not just its title", async () => {
    const res = await fetch(new Request("https://x/app/g"), makeEnv());
    const body = await res.text();
    const script = /<script>([\s\S]*?)<\/script>/.exec(body)?.[1] ?? "";

    // Everything a shared activity carries has to reach the page, or the
    // person holding the link sees a title and nothing that moves.
    for (const field of ["a.subtitle", "a.value", "a.progress", "a.items", "a.endsAt"]) {
      expect(script, field).toContain(field);
    }
    // Items suppress the chart here the way they do on the Lock Screen.
    expect(script).toContain("rows.length");
    expect(body).toContain(".rowsub{");
  });

  it("is not indexed", async () => {
    const res = await fetch(new Request("https://x/app/g"), makeEnv());
    expect(await res.text()).toContain('name="robots" content="noindex,nofollow"');
  });

  // The page's esc() is textContent round-tripped through innerHTML. That is
  // correct for text and wrong for an attribute: HTML text-node serialization
  // does not escape quotes, because a text node never needs them escaped.
  describe("producer-supplied values never reach an attribute by concatenation", () => {
    it("accepts a deepLink carrying a double quote, which is why this matters", () => {
      // The input half of the defect. z.url() validates and returns the string
      // it was given rather than a normalised form, so the raw quote survives
      // into storage and out to every renderer.
      const hostile = 'https://example.com/a" onmouseover="alert(1)';
      const parsed = DashboardCardInputSchema.safeParse({
        id: "hostile",
        template: "list",
        title: "Rooms",
        items: [{ id: "r1", title: "Kitchen", deepLink: hostile }],
      });

      expect(parsed.success).toBe(true);
      expect(parsed.success && parsed.data.items?.[0].deepLink).toBe(hostile);
    });

    it("builds the item anchor through the DOM, not by string concatenation", async () => {
      const res = await fetch(new Request("https://x/app/g"), makeEnv());
      const script = /<script>([\s\S]*?)<\/script>/.exec(await res.text())?.[1] ?? "";

      // The href goes through setAttribute, which cannot be escaped out of.
      expect(script).toContain("var link=function(href,text)");
      expect(script).toContain("a.setAttribute('href',href)");
      expect(script).toContain("link(i.deepLink,i.title)");

      // And the general rule, which is what stops this coming back somewhere
      // else: no esc() output may sit next to an attribute quote, in either
      // order. esc() is the marker for "this value came from a producer", and
      // an attribute is the one place its escaping is not sufficient.
      //
      // Deliberately not a ban on all attribute interpolation. The script
      // builds SVG geometry that way throughout — widths, offsets, and class
      // names looked up in the fixed PIP table — because the CSP forbids
      // inline styles, so per-segment sizing has to be an attribute. Those
      // values are computed numbers and fixed strings, never producer text.
      expect(script).not.toMatch(/="'\s*\+\s*esc\(/);
      expect(script).not.toMatch(/esc\([^)]*\)\s*\+\s*'"/);
    });
  });
});
