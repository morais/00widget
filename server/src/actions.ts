import type { Env } from "./types";
import { RunActionSchema } from "./types";
import { json, badRequest } from "./http";
import type { AuthContext } from "./auth";
import { parseJson } from "./cards";

export async function runAction(
  req: Request,
  _env: Env,
  auth: AuthContext,
  actionId: string,
): Promise<Response> {
  const body = await parseJson(req);
  const parsed = RunActionSchema.safeParse(body ?? {});
  if (!parsed.success) return badRequest(`validation failed: ${parsed.error.message}`);
  // v1 behaviour: log and succeed. Wire this to a configured webhook per API key in v2.
  console.log("action.run", {
    apiKeyHash: auth.apiKeyHash,
    actionId,
    source: parsed.data.source,
    context: parsed.data.context,
  });
  return json({ ok: true, actionId, source: parsed.data.source });
}
