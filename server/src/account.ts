import type { AuthContext } from "./auth";
import { json } from "./http";
import { isReviewTenant } from "./reviewAuth";
import * as storage from "./storage";
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
  env: Env,
  auth: AuthContext,
): Promise<Response> {
  return json({
    account: {
      tenantId: auth.tenantId,
      ownerEmail: auth.ownerEmail ?? null,
      isReviewTenant: isReviewTenant(env, auth.tenantId),
    },
  });
}

/// DELETE /v1/account — erase the tenant and everything it owns.
///
/// Apple requires an account that can be created in an app to be deletable
/// from that same app, and requires deletion rather than deactivation, so this
/// removes rows: there is deliberately no `disabled_at` path here. The tenant's
/// id is freed along with its email address, and signing in again afterwards
/// creates a genuinely new account.
///
/// App-credential only, like `getAccount`. Only a Sign in with Apple round trip
/// mints that kind, so an agent holding a publisher token — or an MCP connector
/// approved through a browser — cannot delete the account it publishes to.
///
/// Not rate limited on purpose. It succeeds once and destroys the credential
/// that authorized it, and charging a tenant bucket would leave a counter row
/// behind for a tenant that no longer exists.
/// Every table that holds something belonging to a tenant, and the column that
/// ties each row to one.
///
/// Exported because it is the whole of account deletion and nothing in the
/// schema enumerates it: there are no cascading deletes here, so a table that
/// is missing from this list keeps its rows after the account is gone, and no
/// ordinary test would notice. `test/accountDeletion.test.ts` reads the
/// migrations and fails when a table appears that is neither listed here nor
/// exempted below.
///
/// Order is content, then credentials, then the tenant itself.
export const TENANT_SCOPED_TABLES: Readonly<Record<string, readonly string[]>> = {
  action_payloads: ["tenant_id"],
  cards: ["tenant_id"],
  devices: ["tenant_id"],
  widget_tokens: ["tenant_id"],
  start_tokens: ["tenant_id"],
  webhook_integrations: ["tenant_id"],
  activity_history: ["tenant_id"],
  widget_push_pending: ["tenant_id"],
  activity_deliveries: ["owner_tenant_id", "target_tenant_id"],
  activity_targets: ["owner_tenant_id", "target_tenant_id"],
  activity_instances: ["owner_tenant_id"],
  // Both directions. An invitation that was never accepted also holds this
  // person's email address in someone else's row; that is handled separately
  // because it matches on the address rather than on a tenant id.
  shares: ["owner_tenant_id", "recipient_tenant_id"],
  // Every credential of every kind, guest links included — they are `api_keys`
  // rows belonging to this tenant.
  api_keys: ["tenant_id"],
  apple_accounts: ["tenant_id"],
  tenants: ["id"],
};

/// Tables deliberately left out of the sweep, with the reason each is safe.
export const ACCOUNT_DELETION_EXEMPT_TABLES: Readonly<Record<string, string>> = {
  // Keyed by APNs token rather than by tenant. Handled in `deleteAccount`,
  // which reads the tokens before the rows naming them are deleted.
  widget_push_cadence: "keyed by push token, deleted per token",
  widget_push_delivery_diagnostics: "keyed by push token, deleted per token",
  // Detached rather than deleted: a subscription is an App Store account, not
  // this one, and the row is what stops a second tenant claiming the same
  // purchase. `tenant_id` goes to NULL, leaving it unclaimed and adoptable.
  subscriptions: "detached by nulling tenant_id, not deleted",
  // Ephemeral counters keyed by a random tenant id, swept on expiry. Deleting
  // them would cost rows written for nothing.
  rate_limit_buckets: "ephemeral, expires on its own",
  // Not tenant data.
  server_settings: "global configuration",
  mcp_authorization_codes: "single-use codes, expire on their own",
};

export async function deleteAccount(
  _req: Request,
  env: Env,
  auth: AuthContext,
): Promise<Response> {
  const tenantId = auth.tenantId;
  if (isReviewTenant(env, tenantId)) {
    return json({ error: "review tenants cannot be deleted" }, 403);
  }
  const ownerEmail = auth.ownerEmail?.trim().toLowerCase() ?? null;

  // The two push-cadence tables are keyed by APNs token rather than by tenant,
  // so the tokens have to be read while the rows naming them still exist.
  const pushTokens = [...new Set(await storage.listWidgetTokens(env, tenantId))];

  const db = env.ZW_DB;

  // One statement per table and column, in the order `TENANT_SCOPED_TABLES`
  // lists them: content, then credentials, then the tenant row. A batch is one
  // transaction, so the order is for the reader rather than for correctness.
  const statements: D1PreparedStatement[] = Object.entries(TENANT_SCOPED_TABLES).flatMap(
    ([table, columns]) =>
      columns.map((column) =>
        db.prepare(`DELETE FROM ${table} WHERE ${column} = ?`).bind(tenantId),
      ),
  );

  // Not a tenant id, so it cannot come from the loop: an invitation that was
  // never accepted holds this person's email address in someone else's row,
  // and that is theirs to have removed.
  if (ownerEmail) {
    statements.push(
      db.prepare(`DELETE FROM shares WHERE lower(recipient_email) = ?`).bind(ownerEmail),
    );
  }

  for (const token of pushTokens) {
    statements.push(db.prepare(`DELETE FROM widget_push_cadence WHERE token = ?`).bind(token));
    statements.push(
      db.prepare(`DELETE FROM widget_push_delivery_diagnostics WHERE token = ?`).bind(token),
    );
  }

  // Detached rather than deleted. A subscription is an App Store account, not
  // this one, and the row is what stops a second tenant from claiming the same
  // purchase; nulling the tenant leaves it unclaimed and adoptable the way an
  // unmatched notification is, without keeping it pointed at a tenant that has
  // gone. Deleting the account does not cancel the subscription — only the App
  // Store can do that, which the app says on the way in.
  statements.push(
    db
      .prepare(`UPDATE subscriptions SET tenant_id = NULL, updated_at = ? WHERE tenant_id = ?`)
      .bind(new Date().toISOString(), tenantId),
  );

  const results = await db.batch(statements);
  const rowsDeleted = results.reduce(
    (total, result) => total + ((result.meta as { changes?: number } | undefined)?.changes ?? 0),
    0,
  );

  // Rate limit buckets are left alone. They are ephemeral counters keyed by a
  // random tenant id, they carry nothing about the person, and they are swept
  // on expiry — deleting them here would cost rows written for no benefit.
  return json({ ok: true, deleted: true, rowsDeleted });
}
