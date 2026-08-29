import { describe, expect, it } from "vitest";
import handler from "../src/index";
import { makeEnv } from "./helpers";

const ctx = {} as ExecutionContext;
const PATH = "/.well-known/openai-apps-challenge";
const TOKEN = "test-openai-verification-token";

const get = (path = PATH, token: string | null = TOKEN) =>
  (handler.fetch as any)(
    new Request(`https://api.example.com${path}`),
    makeEnv(token === null ? {} : { OPENAI_APPS_CHALLENGE_TOKEN: token }),
    ctx,
  ) as Promise<Response>;

describe("openai-apps-challenge", () => {
  it("returns only the configured token as plain text", async () => {
    const res = await get();

    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("text/plain; charset=utf-8");
    expect(await res.text()).toBe(TOKEN);
  });

  it("does not cache a submission-specific challenge", async () => {
    const res = await get();

    expect(res.headers.get("cache-control")).toBe("no-store");
    expect(res.headers.get("x-content-type-options")).toBe("nosniff");
  });

  it("404s when no token is configured", async () => {
    expect((await get(PATH, null)).status).toBe(404);
    expect((await get(PATH, "   ")).status).toBe(404);
  });

  it("is served only from the exact well-known path", async () => {
    expect((await get(`${PATH}/`)).status).toBe(404);
    expect((await get(`${PATH}.txt`)).status).toBe(404);
  });

  it("routes HEAD like GET", async () => {
    const res = await (handler.fetch as any)(
      new Request(`https://api.example.com${PATH}`, { method: "HEAD" }),
      makeEnv({ OPENAI_APPS_CHALLENGE_TOKEN: TOKEN }),
      ctx,
    );

    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("text/plain; charset=utf-8");
  });
});
