import type { Env, DashboardCard } from "./types";

export const keys = {
  card: (hash: string, id: string) => `card:${hash}:${id}`,
  cardsIndex: (hash: string) => `cards-index:${hash}`,
  device: (hash: string, deviceId: string) => `device:${hash}:${deviceId}`,
  widgetToken: (hash: string, deviceId: string, kind: string) =>
    `widget-token:${hash}:${deviceId}:${kind}`,
  activity: (hash: string, externalId: string) => `activity:${hash}:${externalId}`,
  pendingActivity: (hash: string, externalId: string) =>
    `pending-activity:${hash}:${externalId}`,
  startToken: (hash: string, deviceId: string, attributesType: string) =>
    `start-token:${hash}:${deviceId}:${attributesType}`,
};

export interface DeviceRecord {
  apnsDeviceToken?: string;
  appVersion?: string;
  platform?: string;
  updatedAt: string;
}

export interface ActivityRecord {
  pushToken: string;
  deviceId: string;
  localActivityId: string;
  kind: string;
  updatedAt: string;
  lastState?: unknown;
}

export async function putCard(env: Env, hash: string, card: DashboardCard): Promise<void> {
  await env.ZW_KV.put(keys.card(hash, card.id), JSON.stringify(card));
  const indexRaw = await env.ZW_KV.get(keys.cardsIndex(hash));
  const ids: string[] = indexRaw ? JSON.parse(indexRaw) : [];
  if (!ids.includes(card.id)) {
    ids.push(card.id);
    await env.ZW_KV.put(keys.cardsIndex(hash), JSON.stringify(ids));
  }
}

export async function getCard(env: Env, hash: string, id: string): Promise<DashboardCard | null> {
  const raw = await env.ZW_KV.get(keys.card(hash, id));
  if (!raw) return null;
  return JSON.parse(raw) as DashboardCard;
}

export async function listCards(env: Env, hash: string): Promise<DashboardCard[]> {
  const indexRaw = await env.ZW_KV.get(keys.cardsIndex(hash));
  if (!indexRaw) return [];
  const ids: string[] = JSON.parse(indexRaw);
  const cards = await Promise.all(
    ids.map(async (id) => {
      const raw = await env.ZW_KV.get(keys.card(hash, id));
      return raw ? (JSON.parse(raw) as DashboardCard) : null;
    }),
  );
  return cards.filter((c): c is DashboardCard => c !== null);
}

export async function deleteCard(env: Env, hash: string, id: string): Promise<void> {
  await env.ZW_KV.delete(keys.card(hash, id));
  const indexRaw = await env.ZW_KV.get(keys.cardsIndex(hash));
  if (indexRaw) {
    const ids: string[] = JSON.parse(indexRaw);
    const filtered = ids.filter((x) => x !== id);
    await env.ZW_KV.put(keys.cardsIndex(hash), JSON.stringify(filtered));
  }
}

export async function putDevice(
  env: Env,
  hash: string,
  deviceId: string,
  record: DeviceRecord,
): Promise<void> {
  await env.ZW_KV.put(keys.device(hash, deviceId), JSON.stringify(record));
}

export async function putWidgetToken(
  env: Env,
  hash: string,
  deviceId: string,
  widgetKind: string,
  token: string,
): Promise<void> {
  await env.ZW_KV.put(keys.widgetToken(hash, deviceId, widgetKind), token);
}

export async function listWidgetTokens(env: Env, hash: string): Promise<string[]> {
  const prefix = `widget-token:${hash}:`;
  const tokens: string[] = [];
  let cursor: string | undefined;
  do {
    const page = await env.ZW_KV.list({ prefix, cursor });
    for (const k of page.keys) {
      const token = await env.ZW_KV.get(k.name);
      if (token) tokens.push(token);
    }
    cursor = page.list_complete ? undefined : page.cursor;
  } while (cursor);
  return tokens;
}

export async function putActivity(
  env: Env,
  hash: string,
  externalId: string,
  record: ActivityRecord,
): Promise<void> {
  await env.ZW_KV.put(keys.activity(hash, externalId), JSON.stringify(record));
}

export async function getActivity(
  env: Env,
  hash: string,
  externalId: string,
): Promise<ActivityRecord | null> {
  const raw = await env.ZW_KV.get(keys.activity(hash, externalId));
  return raw ? (JSON.parse(raw) as ActivityRecord) : null;
}

export async function deleteActivity(env: Env, hash: string, externalId: string): Promise<void> {
  await env.ZW_KV.delete(keys.activity(hash, externalId));
}

export async function putPendingActivity(
  env: Env,
  hash: string,
  externalId: string,
  record: unknown,
): Promise<void> {
  await env.ZW_KV.put(keys.pendingActivity(hash, externalId), JSON.stringify(record));
}

export async function putStartToken(
  env: Env,
  hash: string,
  deviceId: string,
  attributesType: string,
  pushToken: string,
): Promise<void> {
  await env.ZW_KV.put(keys.startToken(hash, deviceId, attributesType), pushToken);
}

export async function listStartTokens(
  env: Env,
  hash: string,
  attributesType: string,
): Promise<string[]> {
  const prefix = `start-token:${hash}:`;
  const tokens: string[] = [];
  let cursor: string | undefined;
  do {
    const page = await env.ZW_KV.list({ prefix, cursor });
    for (const k of page.keys) {
      if (!k.name.endsWith(`:${attributesType}`)) continue;
      const token = await env.ZW_KV.get(k.name);
      if (token) tokens.push(token);
    }
    cursor = page.list_complete ? undefined : page.cursor;
  } while (cursor);
  return tokens;
}

export async function listPendingActivities(env: Env, hash: string): Promise<unknown[]> {
  const prefix = `pending-activity:${hash}:`;
  const out: unknown[] = [];
  let cursor: string | undefined;
  do {
    const page = await env.ZW_KV.list({ prefix, cursor });
    for (const k of page.keys) {
      const raw = await env.ZW_KV.get(k.name);
      if (raw) out.push(JSON.parse(raw));
    }
    cursor = page.list_complete ? undefined : page.cursor;
  } while (cursor);
  return out;
}
