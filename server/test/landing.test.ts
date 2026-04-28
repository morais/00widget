import { describe, it, expect } from "vitest";
import handler from "../src/index";
import { integrationMarkdown } from "../src/generated/integrationDoc";
import { makeEnv } from "./helpers";

const ctx = {} as ExecutionContext;

describe("public landing + integration endpoints", () => {
  it("GET / returns the landing HTML with the agent prompt", async () => {
    const res = await (handler.fetch as any)(new Request("https://x/"), makeEnv(), ctx);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")?.startsWith("text/html")).toBe(true);
    const body = await res.text();
    expect(body).toContain("Widgets for all your agents");
    expect(body).toContain("Pointing an agent at 00Widget from another project");
    expect(body).toContain("00WIDGET_BASE_URL");
    expect(body).toContain("/integration.md");
  });

  it("GET /integration.md returns INTEGRATION.md as text/markdown", async () => {
    const res = await (handler.fetch as any)(
      new Request("https://x/integration.md"),
      makeEnv(),
      ctx,
    );
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")?.startsWith("text/markdown")).toBe(true);
    const body = await res.text();
    expect(body).toBe(integrationMarkdown);
    // Sanity-check the embedded content matches what the file actually contains.
    expect(body).toContain("# Integrating with 00Widget");
    expect(body).toContain("## TL;DR");
  });

  it("GET /llms.txt returns a discovery document pointing at /integration.md", async () => {
    const res = await (handler.fetch as any)(
      new Request("https://x/llms.txt"),
      makeEnv(),
      ctx,
    );
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")?.startsWith("text/plain")).toBe(true);
    const body = await res.text();
    expect(body).toContain("00Widget");
    expect(body).toContain("/integration.md");
  });

  it("embedded integration markdown matches the source file", async () => {
    // Drift guard. `pretest` runs sync-docs, so this should always pass; if it
    // doesn't, the source file has changed and you forgot to run `npm run sync-docs`.
    const fs = await import("node:fs");
    const path = await import("node:path");
    const url = await import("node:url");
    const here = path.dirname(url.fileURLToPath(import.meta.url));
    const sourceMd = fs.readFileSync(path.resolve(here, "../../docs/INTEGRATION.md"), "utf8");
    expect(integrationMarkdown).toBe(sourceMd);
  });
});
