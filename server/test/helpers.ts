import type { Env } from "../src/types";

export class FakeKV {
  private store = new Map<string, string>();

  async get(key: string): Promise<string | null> {
    return this.store.get(key) ?? null;
  }

  async put(key: string, value: string): Promise<void> {
    this.store.set(key, value);
  }

  async delete(key: string): Promise<void> {
    this.store.delete(key);
  }

  async list(options?: { prefix?: string }): Promise<{ keys: { name: string }[]; list_complete: boolean }> {
    const prefix = options?.prefix ?? "";
    const names = [...this.store.keys()].filter((k) => k.startsWith(prefix)).sort();
    return {
      keys: names.map((name) => ({ name })),
      list_complete: true,
    };
  }
}

export function makeEnv(overrides: Partial<Env> = {}): Env {
  return {
    ZW_KV: new FakeKV() as unknown as KVNamespace,
    API_KEYS: "test-key",
    APNS_TEAM_ID: undefined,
    APNS_KEY_ID: undefined,
    APNS_PRIVATE_KEY: undefined,
    APNS_BUNDLE_ID: "com.example.zerozerowidget",
    APNS_ENV: "sandbox",
    ...overrides,
  };
}

export function authedRequest(url: string, init: RequestInit = {}, apiKey = "test-key"): Request {
  const headers = new Headers(init.headers);
  headers.set("authorization", `Bearer ${apiKey}`);
  if (init.body && !headers.has("content-type")) {
    headers.set("content-type", "application/json");
  }
  return new Request(url, { ...init, headers });
}
