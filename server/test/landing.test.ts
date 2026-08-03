import { describe, it, expect } from "vitest";
import handler from "../src/index";
import { llmsMarkdown } from "../src/generated/llmsDoc";
import { makeEnv } from "./helpers";

const ctx = {} as ExecutionContext;

describe("public landing + docs endpoints", () => {
  it("GET / returns the landing HTML with the agent prompt", async () => {
    const res = await (handler.fetch as any)(new Request("https://x/"), makeEnv(), ctx);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")?.startsWith("text/html")).toBe(true);
    const body = await res.text();
    expect(body).toContain("Widgets for all your agents");
    expect(body).toContain("Pointing an agent at 00Widget from another project");
    expect(body).toContain("00WIDGET_BASE_URL");
    expect(body).toContain("/llms.md");
  });

  it("landing HTML wires a copy button to the agent prompt", async () => {
    const res = await (handler.fetch as any)(new Request("https://x/"), makeEnv(), ctx);
    const body = await res.text();
    // Button + matching target + click handler all present.
    expect(body).toContain('data-copy-target="agent-prompt"');
    expect(body).toContain('id="agent-prompt"');
    expect(body).toContain("navigator.clipboard.writeText");
  });

  it("landing HTML has hash-based browser security headers", async () => {
    const res = await (handler.fetch as any)(new Request("https://x/"), makeEnv(), ctx);
    expect(res.headers.get("x-content-type-options")).toBe("nosniff");
    expect(res.headers.get("referrer-policy")).toBe("no-referrer");
    expect(res.headers.get("x-frame-options")).toBe("DENY");
    expect(res.headers.get("permissions-policy")).toContain("camera=()");

    const csp = res.headers.get("content-security-policy") ?? "";
    expect(csp).toContain("default-src 'none'");
    expect(csp).toContain("frame-ancestors 'none'");
    expect(csp).not.toContain("'unsafe-inline'");
    // A public, cacheable response must not carry a per-request nonce: a shared
    // cache would serve one visitor's nonce to everybody.
    expect(csp).not.toContain("nonce-");
    expect(res.headers.get("cache-control")).toBe("public, max-age=300");
  });

  it("landing CSP hashes match the inline blocks actually served", async () => {
    const res = await (handler.fetch as any)(new Request("https://x/"), makeEnv(), ctx);
    const csp = res.headers.get("content-security-policy") ?? "";
    const body = await res.text();

    const sha256Base64 = async (input: string) => {
      const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
      return btoa(String.fromCharCode(...new Uint8Array(digest)));
    };

    const style = /<style>([\s\S]*?)<\/style>/.exec(body)?.[1];
    const script = /<script>([\s\S]*?)<\/script>/.exec(body)?.[1];
    expect(style).toBeTruthy();
    expect(script).toBeTruthy();

    expect(csp).toContain(`style-src 'sha256-${await sha256Base64(style!)}'`);
    expect(csp).toContain(`script-src 'sha256-${await sha256Base64(script!)}'`);
  });

  it("landing CSP is stable across requests", async () => {
    const first = await (handler.fetch as any)(new Request("https://x/"), makeEnv(), ctx);
    const second = await (handler.fetch as any)(new Request("https://x/"), makeEnv(), ctx);
    expect(first.headers.get("content-security-policy")).toBe(
      second.headers.get("content-security-policy"),
    );
  });

  it("GET /llms.md returns hosted agent markdown as text/markdown", async () => {
    const res = await (handler.fetch as any)(
      new Request("https://x/llms.md"),
      makeEnv(),
      ctx,
    );
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")?.startsWith("text/markdown")).toBe(true);
    const body = await res.text();
    expect(body).not.toBe(llmsMarkdown);
    expect(body).toContain("# Integrating with 00Widget");
    expect(body).toContain("## TL;DR");
    expect(body).toContain("00WIDGET_BASE_URL=https://x");
    expect(body).toContain("do not ask the operator for the base URL");
    expect(body).toContain("Ask the operator only for the API key");
    expect(body).not.toContain(
      "Get two values from the operator: `00WIDGET_BASE_URL` and `00WIDGET_API_KEY`",
    );
  });

  it("GET /llms.txt returns a discovery document pointing at /llms.md", async () => {
    const res = await (handler.fetch as any)(
      new Request("https://x/llms.txt"),
      makeEnv(),
      ctx,
    );
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")?.startsWith("text/plain")).toBe(true);
    const body = await res.text();
    expect(body).toContain("00Widget");
    expect(body).toContain("/llms.md");
  });

  it("embedded llms markdown matches the source file", async () => {
    // Drift guard. `pretest` runs sync-docs, so this should always pass; if it
    // doesn't, the source file has changed and you forgot to run `npm run sync-docs`.
    const fs = await import("node:fs");
    const path = await import("node:path");
    const url = await import("node:url");
    const here = path.dirname(url.fileURLToPath(import.meta.url));
    const sourceMd = fs.readFileSync(path.resolve(here, "../../docs/llms.md"), "utf8");
    expect(llmsMarkdown).toBe(sourceMd);
  });
});
