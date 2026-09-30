import { describe, expect, it } from "vitest";
import handler from "../src/index";
import { jsonForScriptBlock } from "../src/dashboardPage";
import { hashAdminApiToken, makeSessionCookie } from "../src/webSession";
import * as storage from "../src/storage";
import type { Env } from "../src/types";
import { makeEnv } from "./helpers";

const ORIGIN = "https://api.example.com";
const SESSION_SECRET = "test-session-secret-0123456789abcdef";
// Owner of the "test-tenant" that makeEnv seeds; deliberately not an admin.
const OWNER_EMAIL = "test-tenant@example.com";

function env(overrides: Partial<Env> = {}): Env {
  return makeEnv({ SESSION_SECRET, ADMIN_EMAILS: "admin@example.com", ...overrides });
}

function get(e: Env, cookie?: string): Promise<Response> {
  return (handler.fetch as (r: Request, e: Env, c: ExecutionContext) => Promise<Response>)(
    new Request(`${ORIGIN}/dashboard`, cookie ? { headers: { cookie } } : {}),
    e,
    {} as ExecutionContext,
  );
}

async function cookieFor(e: Env, email: string): Promise<string> {
  return (await makeSessionCookie(e, email)).split(";")[0];
}

function card(id: string, title: string) {
  return { id, template: "summary", title, value: "1", status: "good" } as never;
}

function dataBlock(page: string): unknown {
  const match = /<script type="application\/json" id="data">([\s\S]*?)<\/script>/.exec(page);
  if (!match) throw new Error("no data block");
  return JSON.parse(match[1]);
}

describe("GET /dashboard", () => {
  it("sends a signed-out visitor to sign in and back", async () => {
    const res = await get(env());
    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toBe("/login?next=%2Fdashboard");
  });

  it("shows only the signed-in owner's own cards", async () => {
    const e = env();
    await storage.putCard(e, "test-tenant", "test-hash", card("mine", "Mine"));
    await storage.putCard(e, "someone-else", "test-hash", card("theirs", "Theirs"));

    const res = await get(e, await cookieFor(e, OWNER_EMAIL));
    expect(res.status).toBe(200);
    expect(res.headers.get("cache-control")).toBe("no-store");
    const page = await res.text();
    expect(page).toContain('href="/logout?next=%2Fdashboard">Sign out</a>');
    const data = dataBlock(page) as { cards: { id: string }[]; activities: unknown[] };
    expect(data.cards.map((c) => c.id)).toEqual(["mine"]);
    expect(data.activities).toEqual([]);
  });

  it("keeps a hostile card title inside the data block", async () => {
    const e = env();
    await storage.putCard(e, "test-tenant", "test-hash", card("x", "</script><script>alert(1)</script>"));
    const page = await (await get(e, await cookieFor(e, OWNER_EMAIL))).text();
    expect(page).not.toContain("<script>alert(1)");
    expect((dataBlock(page) as { cards: { title: string }[] }).cards[0].title)
      .toBe("</script><script>alert(1)</script>");
  });

  it("renders the embedded data with the shared renderer", async () => {
    const e = env();
    await storage.putCard(e, "test-tenant", "test-hash", card("mine", "Water heater"));
    const page = await (await get(e, await cookieFor(e, OWNER_EMAIL))).text();
    const data = /<script type="application\/json" id="data">([\s\S]*?)<\/script>/.exec(page)![1];
    const script = [...page.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((m) => m[1]).join("\n;\n");
    const nodes: Record<string, { innerHTML: string; textContent: string }> = {
      out: { innerHTML: "", textContent: "" },
      stamp: { innerHTML: "", textContent: "" },
      data: { innerHTML: "", textContent: data },
    };
    // esc() in the renderer escapes through a detached element's textContent.
    const createElement = () => {
      let text = "";
      return {
        set textContent(v: string) { text = String(v).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); },
        get innerHTML() { return text; },
      };
    };
    new Function("document", script)({ getElementById: (id: string) => nodes[id], createElement });
    expect(nodes.out.innerHTML).toContain("dashboard-grid");
    expect(nodes.out.innerHTML).toContain("Water heater");
    expect(nodes.stamp.textContent).toMatch(/^Updated /);
  });

  it("pins every inline script and style by hash and allows no connections", async () => {
    const e = env();
    const res = await get(e, await cookieFor(e, OWNER_EMAIL));
    const csp = res.headers.get("content-security-policy") ?? "";
    expect(csp).toContain("connect-src 'none'");
    expect(csp).not.toContain("unsafe-inline");
    const page = await res.text();
    const scripts = [...page.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((m) => m[1]);
    const styles = [...page.matchAll(/<style>([\s\S]*?)<\/style>/g)].map((m) => m[1]);
    expect(scripts).toHaveLength(2);
    expect(styles).toHaveLength(2);
    for (const source of [...scripts, ...styles]) {
      const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(source));
      const hash = btoa(String.fromCharCode(...new Uint8Array(digest)));
      expect(csp).toContain(`'sha256-${hash}'`);
    }
  });

  it("tells a signed-in person with no account why there is nothing to show", async () => {
    const e = env();
    const res = await get(e, await cookieFor(e, "nobody@example.com"));
    expect(res.status).toBe(409);
    expect(await res.text()).toContain("does not own a 00Widget account");
  });

  it("gives an admin API-token session no tenant's data", async () => {
    const e = env({ ADMIN_API_TOKEN_LOGIN: "true", API_KEYS: "admin-bootstrap-token-0123456789abcdef" });
    const cookie = (await makeSessionCookie(e, "api-token", "api-token", {
      apiTokenHash: await hashAdminApiToken("admin-bootstrap-token-0123456789abcdef"),
    })).split(";")[0];
    const res = await get(e, cookie);
    expect(res.status).toBe(409);
    expect(await res.text()).toContain("/admin");
  });
});

describe("jsonForScriptBlock", () => {
  it("round-trips through JSON.parse with nothing an HTML parser acts on", () => {
    const value = { t: "</script><!-- & \u2028\u2029 >" };
    const encoded = jsonForScriptBlock(value);
    expect(encoded).not.toMatch(/[<>&\u2028\u2029]/);
    expect(JSON.parse(encoded)).toEqual(value);
  });
});
