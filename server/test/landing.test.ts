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

  it("GET /integration.md redirects to /llms.md for compatibility", async () => {
    const res = await (handler.fetch as any)(
      new Request("https://x/integration.md"),
      makeEnv(),
      ctx,
    );
    expect(res.status).toBe(308);
    expect(res.headers.get("location")).toBe("https://x/llms.md");
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
