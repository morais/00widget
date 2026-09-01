import {
  ApiScopePresets,
  createApiKey,
  type CreatedApiKey,
} from "./auth";
import type { Env } from "./types";

export interface AppCredentialBundle extends CreatedApiKey {
  appCredential: string;
  publisherCredential?: string;
}

/// Issue the three credentials an app sign-in needs. Apple and review sign-in
/// differ only in how they prove the tenant; once proven, their device/app/
/// agent credentials intentionally have the same scopes and lifecycle.
export async function issueAppCredentialBundle(
  env: Env,
  input: {
    tenantId?: string;
    ownerEmail: string;
    label: string;
    deviceId?: string;
    issuePublisherCredential?: boolean;
  },
): Promise<AppCredentialBundle> {
  const sessionId = crypto.randomUUID();
  const created = await createApiKey(env, {
    tenantId: input.tenantId,
    ownerEmail: input.ownerEmail,
    label: input.label,
    kind: "publisher",
    purpose: "device",
    sessionId,
    deviceId: input.deviceId,
    scopes: ApiScopePresets.device,
  });
  const appCredential = await createApiKey(env, {
    tenantId: created.tenant.id,
    ownerEmail: created.tenant.ownerEmail,
    label: `${input.label} (app only)`,
    kind: "app",
    purpose: "app",
    sessionId,
    deviceId: input.deviceId,
    scopes: ApiScopePresets.appOnly,
  });
  const publisherCredential = input.issuePublisherCredential === false
    ? null
    : await createApiKey(env, {
        tenantId: created.tenant.id,
        ownerEmail: created.tenant.ownerEmail,
        label: `${input.label} (agent publisher)`,
        kind: "publisher",
        purpose: "agent",
        // An agent token belongs to the account. It deliberately has neither
        // the phone's session id nor its device id, so signing out one device
        // cannot stop an agent that may be running somewhere else.
        scopes: ApiScopePresets.producer,
      });

  return {
    ...created,
    appCredential: appCredential.token,
    ...(publisherCredential ? { publisherCredential: publisherCredential.token } : {}),
  };
}
