import { it, expect } from "vitest";
import { handleMcp } from "../src/mcp";
import { authedRequest, makeEnv } from "./helpers";
import { sha256Hex } from "../src/auth";

// Captured from the pre-setup implementation and compared against it in full
// during development. Setup must not require connector/plugin resubmission.
const PRE_SETUP_DESCRIPTOR_HASH = "410e19b22cc0f77ce599e130e72f9fbd8746a55d6e790bf6ef571fda112d890e";

it("keeps the original tool descriptors unchanged by setup guidance", async () => {
  const env = makeEnv({ MCP_ENABLED: "true", SESSION_SECRET: "contract-probe-secret-0123456789abcdef" });
  const res = await handleMcp(authedRequest("https://x/mcp", {
    method: "POST", body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list" }),
  }), env, {} as ExecutionContext);
  const { result: { tools } } = await res.json() as { result: { tools: Array<{
    name: string;
    securitySchemes: unknown;
  }> } };
  // This baseline predates the additive render tools and public OAuth discovery.
  const baselineFields = tools
    .filter((tool) => !tool.name.startsWith("render_"))
    .map(({ securitySchemes: _addedForPublicDiscovery, ...descriptor }) => descriptor);
  expect(await sha256Hex(JSON.stringify(baselineFields))).toBe(PRE_SETUP_DESCRIPTOR_HASH);
});
