import { it, expect } from "vitest";
import { handleMcp as current } from "../src/mcp";
import { authedRequest, makeEnv } from "./helpers";
import { sha256Hex } from "../src/auth";

// Captured from the pre-setup implementation and compared against it in full
// during development. Setup must not require connector/plugin resubmission.
const PRE_SETUP_DESCRIPTOR_HASHES = {
  stable: "410e19b22cc0f77ce599e130e72f9fbd8746a55d6e790bf6ef571fda112d890e",
  preview: "c4e95ad4056380af2b44fd2fb7b06ef9606decba155ba4b2f9e5415862bf6728",
};

it("keeps all published tool descriptors unchanged by setup guidance", async () => {
  const env = makeEnv({ MCP_ENABLED: "true", MCP_PREVIEW_ENABLED: "true", SESSION_SECRET: "contract-probe-secret-0123456789abcdef" });
  for (const channel of ["stable", "preview"] as const) {
    const read = async (implementation: typeof current) => {
      const res = await implementation(authedRequest("https://x/mcp", {
        method: "POST", body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list" }),
      }), env, {} as ExecutionContext, channel);
      return (await res.json() as { result: { tools: unknown[] } }).result.tools;
    };
    const after = await read(current);
    expect(await sha256Hex(JSON.stringify(after)), channel).toBe(PRE_SETUP_DESCRIPTOR_HASHES[channel]);
  }
});
