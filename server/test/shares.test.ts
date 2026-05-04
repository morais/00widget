import { describe, it, expect } from "vitest";
import handler from "../src/index";
import { makeEnv, authedRequest, seedApiKey } from "./helpers";
import * as storage from "../src/storage";
import { sha256Hex } from "../src/auth";

const executionCtx = {} as ExecutionContext;

function withSharing(env: ReturnType<typeof makeEnv>): ReturnType<typeof makeEnv> {
  env.SHARING_ENABLED = "true";
  return env;
}

async function seedCard(env: ReturnType<typeof makeEnv>, tenantId: string, key: string, id: string, title: string) {
  const hash = await sha256Hex(key);
  await storage.putCard(env, tenantId, hash, {
    id,
    template: "metric",
    title,
    value: "1",
    status: "good",
  });
}

describe("shares — kill switch", () => {
  it("returns 503 on every share endpoint when SHARING_ENABLED is unset", async () => {
    const env = makeEnv();
    const post = await (handler.fetch as any)(
      authedRequest("https://x/v1/shares", {
        method: "POST",
        body: JSON.stringify({
          recipientEmail: "x@example.com",
          resourceKind: "card",
          resourceId: "c1",
        }),
      }),
      env,
      executionCtx,
    );
    expect(post.status).toBe(503);

    const out = await (handler.fetch as any)(
      authedRequest("https://x/v1/shares/outgoing"),
      env,
      executionCtx,
    );
    expect(out.status).toBe(503);

    const inc = await (handler.fetch as any)(
      authedRequest("https://x/v1/shares/incoming"),
      env,
      executionCtx,
    );
    expect(inc.status).toBe(503);
  });

  it("does not expose shared cards via include=shared when sharing is disabled", async () => {
    const env = makeEnv();
    await seedApiKey(env, "owner-key", "owner");
    await seedCard(env, "owner", "owner-key", "solar", "Solar");

    const list = await (handler.fetch as any)(
      authedRequest("https://x/v1/cards?include=shared", {}, "owner-key"),
      env,
      executionCtx,
    );
    const data = (await list.json()) as { cards: unknown[]; shared?: unknown[] };
    expect(data.shared).toBeUndefined();
  });
});

describe("shares — happy path", () => {
  async function bootstrap() {
    const env = withSharing(makeEnv());
    await seedApiKey(env, "owner-key", "owner");
    await seedApiKey(env, "recipient-key", "recipient");
    await seedCard(env, "owner", "owner-key", "solar", "Solar");
    return env;
  }

  it("creates a pending share, recipient accepts, then sees it via include=shared", async () => {
    const env = await bootstrap();

    const create = await (handler.fetch as any)(
      authedRequest(
        "https://x/v1/shares",
        {
          method: "POST",
          body: JSON.stringify({
            recipientEmail: "recipient@example.com",
            resourceKind: "card",
            resourceId: "solar",
          }),
        },
        "owner-key",
      ),
      env,
      executionCtx,
    );
    expect(create.status).toBe(201);
    const { share } = (await create.json()) as { share: { id: string; status: string; recipientTenantId?: string } };
    expect(share.status).toBe("pending");
    expect(share.recipientTenantId).toBe("recipient");

    // Owner sees it as outgoing
    const outgoing = await (handler.fetch as any)(
      authedRequest("https://x/v1/shares/outgoing", {}, "owner-key"),
      env,
      executionCtx,
    );
    expect(((await outgoing.json()) as { shares: unknown[] }).shares).toHaveLength(1);

    // Recipient sees it as incoming
    const incoming = await (handler.fetch as any)(
      authedRequest("https://x/v1/shares/incoming", {}, "recipient-key"),
      env,
      executionCtx,
    );
    const incData = (await incoming.json()) as {
      shares: Array<{ id: string; ownerEmail: string; status: string }>;
    };
    expect(incData.shares).toHaveLength(1);
    expect(incData.shares[0].ownerEmail).toBe("owner@example.com");

    // Recipient accepts
    const accept = await (handler.fetch as any)(
      authedRequest(`https://x/v1/shares/${share.id}/accept`, { method: "POST" }, "recipient-key"),
      env,
      executionCtx,
    );
    expect(accept.status).toBe(200);

    // Recipient now gets the card via include=shared
    const list = await (handler.fetch as any)(
      authedRequest("https://x/v1/cards?include=shared", {}, "recipient-key"),
      env,
      executionCtx,
    );
    const listData = (await list.json()) as {
      cards: unknown[];
      shared: Array<{ id: string; sharedBy: { ownerEmail: string } }>;
    };
    expect(listData.cards).toHaveLength(0);
    expect(listData.shared).toHaveLength(1);
    expect(listData.shared[0].id).toBe("solar");
    expect(listData.shared[0].sharedBy.ownerEmail).toBe("owner@example.com");
  });

  it("revoke makes the shared card disappear for the recipient", async () => {
    const env = await bootstrap();

    const create = await (handler.fetch as any)(
      authedRequest(
        "https://x/v1/shares",
        {
          method: "POST",
          body: JSON.stringify({
            recipientEmail: "recipient@example.com",
            resourceKind: "card",
            resourceId: "solar",
          }),
        },
        "owner-key",
      ),
      env,
      executionCtx,
    );
    const { share } = (await create.json()) as { share: { id: string } };

    await (handler.fetch as any)(
      authedRequest(`https://x/v1/shares/${share.id}/accept`, { method: "POST" }, "recipient-key"),
      env,
      executionCtx,
    );

    // Owner revokes.
    const revoke = await (handler.fetch as any)(
      authedRequest(`https://x/v1/shares/${share.id}`, { method: "DELETE" }, "owner-key"),
      env,
      executionCtx,
    );
    expect(revoke.status).toBe(200);

    const list = await (handler.fetch as any)(
      authedRequest("https://x/v1/cards?include=shared", {}, "recipient-key"),
      env,
      executionCtx,
    );
    const listData = (await list.json()) as { shared: unknown[] };
    expect(listData.shared).toHaveLength(0);
  });

  it("decline removes invite from recipient's incoming list", async () => {
    const env = await bootstrap();

    const create = await (handler.fetch as any)(
      authedRequest(
        "https://x/v1/shares",
        {
          method: "POST",
          body: JSON.stringify({
            recipientEmail: "recipient@example.com",
            resourceKind: "card",
            resourceId: "solar",
          }),
        },
        "owner-key",
      ),
      env,
      executionCtx,
    );
    const { share } = (await create.json()) as { share: { id: string } };

    const decline = await (handler.fetch as any)(
      authedRequest(`https://x/v1/shares/${share.id}/decline`, { method: "POST" }, "recipient-key"),
      env,
      executionCtx,
    );
    expect(decline.status).toBe(200);

    const incoming = await (handler.fetch as any)(
      authedRequest("https://x/v1/shares/incoming", {}, "recipient-key"),
      env,
      executionCtx,
    );
    expect(((await incoming.json()) as { shares: unknown[] }).shares).toHaveLength(0);
  });

  it("rejects sharing a non-existent card", async () => {
    const env = await bootstrap();

    const create = await (handler.fetch as any)(
      authedRequest(
        "https://x/v1/shares",
        {
          method: "POST",
          body: JSON.stringify({
            recipientEmail: "recipient@example.com",
            resourceKind: "card",
            resourceId: "no-such-card",
          }),
        },
        "owner-key",
      ),
      env,
      executionCtx,
    );
    expect(create.status).toBe(404);
  });

  it("rejects sharing with self", async () => {
    const env = await bootstrap();

    const create = await (handler.fetch as any)(
      authedRequest(
        "https://x/v1/shares",
        {
          method: "POST",
          body: JSON.stringify({
            recipientEmail: "owner@example.com",
            resourceKind: "card",
            resourceId: "solar",
          }),
        },
        "owner-key",
      ),
      env,
      executionCtx,
    );
    expect(create.status).toBe(400);
  });

  it("rejects duplicate active shares", async () => {
    const env = await bootstrap();

    const body = JSON.stringify({
      recipientEmail: "recipient@example.com",
      resourceKind: "card",
      resourceId: "solar",
    });
    const first = await (handler.fetch as any)(
      authedRequest("https://x/v1/shares", { method: "POST", body }, "owner-key"),
      env,
      executionCtx,
    );
    expect(first.status).toBe(201);
    const second = await (handler.fetch as any)(
      authedRequest("https://x/v1/shares", { method: "POST", body }, "owner-key"),
      env,
      executionCtx,
    );
    expect(second.status).toBe(409);
  });

  it("deleting the underlying card revokes the share automatically", async () => {
    const env = await bootstrap();

    const create = await (handler.fetch as any)(
      authedRequest(
        "https://x/v1/shares",
        {
          method: "POST",
          body: JSON.stringify({
            recipientEmail: "recipient@example.com",
            resourceKind: "card",
            resourceId: "solar",
          }),
        },
        "owner-key",
      ),
      env,
      executionCtx,
    );
    const { share } = (await create.json()) as { share: { id: string } };

    await (handler.fetch as any)(
      authedRequest(`https://x/v1/shares/${share.id}/accept`, { method: "POST" }, "recipient-key"),
      env,
      executionCtx,
    );

    await (handler.fetch as any)(
      authedRequest("https://x/v1/cards/solar", { method: "DELETE" }, "owner-key"),
      env,
      executionCtx,
    );

    const list = await (handler.fetch as any)(
      authedRequest("https://x/v1/cards?include=shared", {}, "recipient-key"),
      env,
      executionCtx,
    );
    expect(((await list.json()) as { shared: unknown[] }).shared).toHaveLength(0);
  });
});
