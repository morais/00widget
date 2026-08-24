import type { AuthContext } from "./auth";
import { json } from "./http";
import type { Env } from "./types";

/// GET /v1/account — who this device is signed in as.
///
/// The app writes the owner email once, from the sign-in response, and keeps
/// it in UserDefaults. Keychain outlives an uninstall and UserDefaults does
/// not, so a reinstall leaves a device still authenticated with nothing to
/// show for it. This is how it asks again.
///
/// Restricted to the `app` credential kind. The device token, the agent
/// publisher token and every MCP connector token are all `kind: "publisher"`,
/// so kind is the only thing that separates the app itself from an agent the
/// operator handed a token to — and an agent has no business reading the
/// operator's email address.
export async function getAccount(
  _req: Request,
  _env: Env,
  auth: AuthContext,
): Promise<Response> {
  return json({
    account: {
      tenantId: auth.tenantId,
      ownerEmail: auth.ownerEmail ?? null,
    },
  });
}
