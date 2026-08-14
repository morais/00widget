import { describe, it, expect } from "vitest";
import handler from "../src/index";
import { makeEnv } from "./helpers";

const ctx = {} as ExecutionContext;
const PATH = "/.well-known/apple-app-site-association";
const APP_ID = "ABCDE12345.com.example.zerozerowidget";

const get = (path = PATH, env = makeEnv({ APPLE_APP_ID: APP_ID })) =>
  (handler.fetch as any)(new Request(`https://x${path}`), env, ctx) as Promise<Response>;

describe("apple-app-site-association", () => {
  it("serves the association as application/json", async () => {
    const res = await get();
    expect(res.status).toBe(200);
    // Apple rejects anything else, and does so silently — links just keep
    // opening in Safari with no diagnostic on device or in the logs.
    expect(res.headers.get("content-type")).toBe("application/json");
  });

  it("claims the configured app ID under the app link prefix", async () => {
    const body = (await (await get()).json()) as any;
    expect(body.applinks.details[0].appIDs).toEqual([APP_ID]);
    expect(body.applinks.details[0].components[0]["/"]).toBe("/app/*");
  });

  it("does not claim the browser-only paths", async () => {
    const body = (await (await get()).json()) as any;
    const claimed: string[] = body.applinks.details.flatMap((d: any) =>
      d.components.map((c: any) => c["/"]),
    );
    // /admin/* is a web Sign in with Apple flow that breaks if iOS diverts it
    // into the app; the landing and docs paths are meant to be read in a
    // browser. A "*" claim would capture every one of them.
    expect(claimed).not.toContain("*");
    for (const path of ["/", "/admin/login", "/llms.md", "/llms.txt", "/v1/cards"]) {
      expect(claimed.some((c) => c === path || c === "*"), path).toBe(false);
    }
  });

  it("omits appclips until a clip ID is configured", async () => {
    const body = (await (await get()).json()) as any;
    expect(body.appclips).toBeUndefined();
  });

  it("claims the App Clip when one is configured", async () => {
    const env = makeEnv({ APPLE_APP_ID: APP_ID, APPLE_APP_CLIP_ID: `${APP_ID}.Clip` });
    const body = (await (await get(PATH, env)).json()) as any;
    expect(body.appclips.apps).toEqual([`${APP_ID}.Clip`]);
    // The full app keeps its own claim — a clip does not replace it.
    expect(body.applinks.details[0].appIDs).toEqual([APP_ID]);
  });

  it("404s when no app ID is configured", async () => {
    // An association listing no appIDs is a valid document that tells iOS "no
    // app handles this domain" — and Apple's CDN caches that answer. A fork
    // with no app must not publish it.
    const res = await get(PATH, makeEnv());
    expect(res.status).toBe(404);
  });

  it("is not served from a path Apple never requests", async () => {
    // Apple fetches the extensionless path and does not follow redirects, so a
    // .json alias would be a trap: it looks right in a browser and is invisible
    // to the device.
    const res = await get(`${PATH}.json`);
    expect(res.status).toBe(404);
    const withSlash = await get(`${PATH}/`);
    expect(withSlash.status).toBe(404);
  });

  it("is cacheable and not marked sensitive", async () => {
    const res = await get();
    expect(res.headers.get("cache-control")).toBe("public, max-age=3600");
    expect(res.headers.get("x-content-type-options")).toBe("nosniff");
  });

  it("HEAD is routed like GET", async () => {
    const res = await (handler.fetch as any)(
      new Request(`https://x${PATH}`, { method: "HEAD" }),
      makeEnv({ APPLE_APP_ID: APP_ID }),
      ctx,
    );
    expect(res.status).toBe(200);
  });
});
