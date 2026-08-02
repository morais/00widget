import { z } from "zod";

const KiB = 1024;

export const RequestBodyLimits = {
  card: 32 * KiB,
  cardBatch: 128 * KiB,
  liveActivity: 16 * KiB,
  registration: 8 * KiB,
  actionRun: 4 * KiB,
  webhookIntegration: 4 * KiB,
  share: 4 * KiB,
  appleLogin: 16 * KiB,
} as const;

export const FieldLimits = {
  id: 96,
  cardId: 96,
  cardBatchCount: 32,
  title: 120,
  subtitle: 240,
  value: 80,
  unit: 24,
  icon: 64,
  deepLink: 2048,
  itemCount: 20,
  actionCount: 8,
  actionLabel: 80,
  actionPayloadKeys: 16,
  actionPayloadKey: 64,
  actionPayloadValue: 512,
  actionPayloadBytes: 4 * KiB,
  externalActivityId: 128,
  activityState: 120,
  alertTitle: 120,
  alertBody: 240,
  deviceId: 128,
  localActivityId: 128,
  widgetKind: 128,
  widgetSubscriptionCount: 64,
  widgetSubscriptionCardCount: 64,
  attributesType: 128,
  pushToken: 4096,
  appVersion: 64,
  platform: 32,
  source: 32,
  email: 254,
  webhookUrl: 2048,
  appleIdentityToken: 12 * KiB,
  apiKeyLabel: 80,
} as const;

const IdString = z.string().min(1).max(FieldLimits.id);
const CardIdString = z.string().min(1).max(FieldLimits.cardId);
const TitleString = z.string().min(1).max(FieldLimits.title);
const OptionalSubtitleString = z.string().max(FieldLimits.subtitle).optional();
const OptionalValueString = z.string().max(FieldLimits.value).optional();
const OptionalUnitString = z.string().max(FieldLimits.unit).optional();
const OptionalIconString = z.string().max(FieldLimits.icon).optional();
const OptionalDeepLink = z
  .string()
  .url()
  .max(FieldLimits.deepLink)
  .refine((value) => {
    try {
      return new URL(value).protocol === "https:";
    } catch {
      return false;
    }
  }, {
    message: "deepLink must use https",
  })
  .optional();
// APNs device tokens and ActivityKit push tokens are hex strings (iOS hands
// them out via Data.hexEncodedString()). Requiring hex here keeps the value
// safe to interpolate into the APNs URL `/3/device/<token>` and rejects
// obviously-malformed input at the boundary.
const PushTokenString = z
  .string()
  .min(1)
  .max(FieldLimits.pushToken)
  .regex(/^[A-Fa-f0-9]+$/, "push token must be hex");

export const DashboardStatusSchema = z
  .enum([
    "unknown",
    "good",
    "warning",
    "critical",
    "running",
    "finished",
    "paused",
    "offline",
  ])
  .catch("unknown");

export const DashboardTemplateSchema = z.enum(["summary", "progress", "list", "action"]);

export const ActionRoleSchema = z.enum(["normal", "destructive"]);

const ActionPayloadSchema = z
  .record(
    z.string().min(1).max(FieldLimits.actionPayloadKey),
    z.string().max(FieldLimits.actionPayloadValue),
  )
  .refine((payload) => Object.keys(payload).length <= FieldLimits.actionPayloadKeys, {
    message: `must have at most ${FieldLimits.actionPayloadKeys} keys`,
  })
  .refine((payload) => JSON.stringify(payload).length <= FieldLimits.actionPayloadBytes, {
    message: `must serialize to at most ${FieldLimits.actionPayloadBytes} bytes`,
  });

export const ActionDefinitionSchema = z.object({
  id: IdString,
  label: z.string().min(1).max(FieldLimits.actionLabel),
  role: ActionRoleSchema.default("normal"),
  confirm: z.boolean().default(false),
  payload: ActionPayloadSchema.optional(),
});

export const DashboardItemSchema = z.object({
  id: IdString,
  title: TitleString,
  subtitle: OptionalSubtitleString,
  value: OptionalValueString,
  unit: OptionalUnitString,
  status: DashboardStatusSchema.optional(),
});

const IsoDate = z.string().refine((s) => !Number.isNaN(Date.parse(s)), {
  message: "must be an ISO-8601 date",
});

const PublicHttpsUrl = z
  .string()
  .url()
  .max(FieldLimits.webhookUrl)
  .refine((s) => {
    try {
      const url = new URL(s);
      if (url.protocol !== "https:") return false;
      return !isBlockedWebhookHostname(url.hostname);
    } catch {
      return false;
    }
  }, {
    message: "must be a public https URL",
  });

export const SharedByInfoSchema = z.object({
  ownerEmail: z.string().max(FieldLimits.email),
  shareId: z.string().max(FieldLimits.id),
});

export const DashboardCardSchema = z.object({
  id: CardIdString,
  template: DashboardTemplateSchema,
  title: TitleString,
  subtitle: OptionalSubtitleString,
  value: OptionalValueString,
  unit: OptionalUnitString,
  status: DashboardStatusSchema.default("unknown"),
  icon: OptionalIconString,
  statusIcon: OptionalIconString,
  updatedAt: IsoDate.optional(),
  staleAfter: IsoDate.optional(),
  deepLink: OptionalDeepLink,
  items: z.array(DashboardItemSchema).max(FieldLimits.itemCount).optional(),
  actions: z.array(ActionDefinitionSchema).max(FieldLimits.actionCount).optional(),
  // Set on cards returned via ?include=shared. Not persisted; not accepted on
  // upsert (zod will strip it because we don't .strict()).
  sharedBy: SharedByInfoSchema.optional(),
});

export const BatchUpsertCardsSchema = z
  .object({
    cards: z
      .array(DashboardCardSchema)
      .min(1)
      .max(FieldLimits.cardBatchCount),
  })
  .superRefine((value, ctx) => {
    const seen = new Set<string>();
    for (const [index, card] of value.cards.entries()) {
      if (seen.has(card.id)) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          path: ["cards", index, "id"],
          message: "card ids must be unique within a batch",
        });
      }
      seen.add(card.id);
    }
  });

export const LiveActivityKindSchema = z
  .enum(["generic", "progress", "charging", "appliance", "job", "timer"])
  .catch("generic");

export const CountdownGranularitySchema = z.enum(["second", "minute"]);

export const RegisterDeviceSchema = z.object({
  deviceId: z.string().min(1).max(FieldLimits.deviceId),
  apnsDeviceToken: PushTokenString.optional(),
  appVersion: z.string().max(FieldLimits.appVersion).default("0.0"),
  platform: z.string().max(FieldLimits.platform).default("ios"),
});

const LegacyRegisterWidgetPushTokenSchema = z.object({
  deviceId: z.string().min(1).max(FieldLimits.deviceId),
  widgetKind: z.string().min(1).max(FieldLimits.widgetKind),
  widgetPushToken: PushTokenString,
});

export const WidgetPushSubscriptionSchema = z.object({
  widgetKind: z.string().min(1).max(FieldLimits.widgetKind),
  cardIds: z
    .array(CardIdString)
    .max(FieldLimits.widgetSubscriptionCardCount)
    .default([]),
  allCards: z.boolean().default(false),
});

const SyncWidgetPushTokenSchema = z
  .object({
    deviceId: z.string().min(1).max(FieldLimits.deviceId),
    widgetPushToken: PushTokenString.optional(),
    subscriptions: z
      .array(WidgetPushSubscriptionSchema)
      .max(FieldLimits.widgetSubscriptionCount),
    appVersion: z.string().max(FieldLimits.appVersion).default("0.0"),
    platform: z.string().max(FieldLimits.platform).default("ios"),
  })
  .superRefine((value, ctx) => {
    if (value.subscriptions.length > 0 && !value.widgetPushToken) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ["widgetPushToken"],
        message: "widgetPushToken is required when subscriptions are present",
      });
    }
  });

// Keep accepting the original one-kind registration until every installed app
// has moved to canonical subscription snapshots.
export const RegisterWidgetPushTokenSchema = z.union([
  SyncWidgetPushTokenSchema,
  LegacyRegisterWidgetPushTokenSchema,
]);

export const RegisterLiveActivitySchema = z.object({
  deviceId: z.string().min(1).max(FieldLimits.deviceId),
  localActivityId: z.string().min(1).max(FieldLimits.localActivityId),
  externalActivityId: z.string().min(1).max(FieldLimits.externalActivityId),
  kind: LiveActivityKindSchema,
  pushToken: PushTokenString,
});

export const RegisterLiveActivityStartTokenSchema = z.object({
  deviceId: z.string().min(1).max(FieldLimits.deviceId),
  attributesType: z.string().min(1).max(FieldLimits.attributesType),
  pushToken: PushTokenString,
});

export const StartLiveActivitySchema = z.object({
  externalActivityId: z.string().min(1).max(FieldLimits.externalActivityId),
  kind: LiveActivityKindSchema,
  title: TitleString,
  subtitle: OptionalSubtitleString,
  state: z.string().min(1).max(FieldLimits.activityState),
  icon: OptionalIconString,
  value: OptionalValueString,
  unit: OptionalUnitString,
  progress: z.number().min(0).max(1).optional(),
  endsAt: IsoDate.optional(),
  countdownGranularity: CountdownGranularitySchema.optional(),
  staleAt: IsoDate.optional(),
  // Surfaced as aps.relevance-score on the APNs payload — Smart Stack on
  // iPhone and Apple Watch ranks Live Activities by this. Range is 0+;
  // larger wins. ActivityKit clamps/normalizes; we just pass through.
  relevanceScore: z.number().min(0).optional(),
  deepLink: OptionalDeepLink,
  alert: z
    .object({
      title: z.string().min(1).max(FieldLimits.alertTitle),
      body: z.string().max(FieldLimits.alertBody).optional(),
    })
    .optional(),
});

export const UpdateLiveActivitySchema = z.object({
  externalActivityId: z.string().min(1).max(FieldLimits.externalActivityId),
  state: z.string().min(1).max(FieldLimits.activityState).optional(),
  title: z.string().min(1).max(FieldLimits.title).optional(),
  subtitle: OptionalSubtitleString,
  icon: OptionalIconString,
  value: OptionalValueString,
  unit: OptionalUnitString,
  progress: z.number().min(0).max(1).optional(),
  endsAt: IsoDate.optional(),
  countdownGranularity: CountdownGranularitySchema.optional(),
  staleAt: IsoDate.optional(),
  relevanceScore: z.number().min(0).optional(),
  alert: z
    .object({
      title: z.string().min(1).max(FieldLimits.alertTitle),
      body: z.string().max(FieldLimits.alertBody).optional(),
    })
    .optional(),
});

export const LiveActivitySessionSchema = z.object({
  externalActivityId: z.string().min(1).max(FieldLimits.externalActivityId),
  kind: LiveActivityKindSchema,
  title: TitleString,
  subtitle: OptionalSubtitleString,
  state: z.string().min(1).max(FieldLimits.activityState),
  icon: OptionalIconString,
  value: OptionalValueString,
  unit: OptionalUnitString,
  progress: z.number().min(0).max(1).optional(),
  endsAt: IsoDate.optional(),
  countdownGranularity: CountdownGranularitySchema.optional(),
  startedAt: IsoDate.optional(),
  updatedAt: IsoDate,
  staleAt: IsoDate.optional(),
  relevanceScore: z.number().min(0).optional(),
  deepLink: OptionalDeepLink,
});

export const EndLiveActivitySchema = z.object({
  externalActivityId: z.string().min(1).max(FieldLimits.externalActivityId),
  finalTitle: z.string().max(FieldLimits.title).optional(),
  finalSubtitle: OptionalSubtitleString,
  finalState: z.string().max(FieldLimits.activityState).optional(),
  dismissalDate: IsoDate.optional(),
});

export const RunActionSchema = z.object({
  context: z
    .object({
      cardId: z.string().max(FieldLimits.cardId).optional(),
    })
    .optional(),
});

export const WebhookIntegrationSchema = z.object({
  url: PublicHttpsUrl,
  rotateSecret: z.boolean().default(false),
});

// SSRF guard for tenant-supplied webhook URLs. The check is **hostname-based**:
// it rejects literal private/loopback/link-local IPs and the `localhost`/`.local`
// names, but does not resolve DNS, so a public hostname that resolves to an
// internal IP (or a DNS-rebind attack) will pass this filter. We rely on the
// Cloudflare Workers runtime to gate the actual fetch — Workers have no
// reachable private network and no cloud metadata endpoint — and on tenant
// authentication to limit who can configure a webhook in the first place.
// Re-evaluate this trade-off if this code ever runs outside Workers.
function isBlockedWebhookHostname(hostname: string): boolean {
  const host = hostname.toLowerCase().replace(/^\[|\]$/g, "").replace(/\.$/, "");
  if (
    host === "localhost" ||
    host === "0.0.0.0" ||
    host === "::" ||
    host === "::1" ||
    host.endsWith(".localhost") ||
    host.endsWith(".local")
  ) {
    return true;
  }
  if (isPrivateIpv4(host)) return true;
  if (isBlockedIpv6(host)) return true;
  return false;
}

function isPrivateIpv4(host: string): boolean {
  const parts = host.split(".");
  if (parts.length !== 4) return false;
  const nums = parts.map((part) => Number(part));
  if (nums.some((n, i) => !Number.isInteger(n) || n < 0 || n > 255 || String(n) !== parts[i])) {
    return false;
  }
  const [a, b] = nums;
  return (
    a === 0 ||
    a === 10 ||
    a === 127 ||
    (a === 169 && b === 254) ||
    (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 168)
  );
}

function isBlockedIpv6(host: string): boolean {
  if (!host.includes(":")) return false;
  return (
    host === "1" ||
    host === "::1" ||
    host.startsWith("fc") ||
    host.startsWith("fd") ||
    host.startsWith("fe80:")
  );
}

export const ShareResourceKindSchema = z.enum(["card", "activity_kind"]);

export const ShareStatusSchema = z.enum(["pending", "accepted", "revoked", "declined"]);

export const CreateShareSchema = z.object({
  recipientEmail: z.string().email().max(FieldLimits.email),
  resourceKind: ShareResourceKindSchema,
  resourceId: z.string().min(1).max(FieldLimits.externalActivityId),
});

export type DashboardCard = z.infer<typeof DashboardCardSchema>;
export type BatchUpsertCards = z.infer<typeof BatchUpsertCardsSchema>;
export type DashboardItem = z.infer<typeof DashboardItemSchema>;
export type ActionDefinition = z.infer<typeof ActionDefinitionSchema>;
export type RegisterDevice = z.infer<typeof RegisterDeviceSchema>;
export type RegisterWidgetPushToken = z.infer<typeof RegisterWidgetPushTokenSchema>;
export type RegisterLiveActivity = z.infer<typeof RegisterLiveActivitySchema>;
export type RegisterLiveActivityStartToken = z.infer<typeof RegisterLiveActivityStartTokenSchema>;
export type CountdownGranularity = z.infer<typeof CountdownGranularitySchema>;
export type StartLiveActivity = z.infer<typeof StartLiveActivitySchema>;
export type UpdateLiveActivity = z.infer<typeof UpdateLiveActivitySchema>;
export type LiveActivitySession = z.infer<typeof LiveActivitySessionSchema>;
export type EndLiveActivity = z.infer<typeof EndLiveActivitySchema>;
export type RunAction = z.infer<typeof RunActionSchema>;
export type WebhookIntegration = z.infer<typeof WebhookIntegrationSchema>;
export type ShareResourceKind = z.infer<typeof ShareResourceKindSchema>;
export type ShareStatus = z.infer<typeof ShareStatusSchema>;
export type CreateShareRequest = z.infer<typeof CreateShareSchema>;

export interface WidgetReloadQueueMessage {
  tenantId: string;
}

export interface Env {
  ZW_DB: D1Database;
  WIDGET_RELOAD_QUEUE?: Queue<WidgetReloadQueueMessage>;
  API_KEYS?: string;
  APNS_TEAM_ID?: string;
  APNS_KEY_ID?: string;
  APNS_PRIVATE_KEY?: string;
  APNS_BUNDLE_ID?: string;
  APNS_ENV?: "sandbox" | "production";

  // Admin dashboard (Sign in with Apple)
  APPLE_SIGN_IN_CLIENT_ID?: string;       // Services ID, e.g. com.example.zerozerowidget.signin
  APPLE_SIGN_IN_REDIRECT_URI?: string;    // full URL of /admin/auth/apple/callback
  ADMIN_EMAILS?: string;                  // comma-separated allowed emails
  SESSION_SECRET?: string;                // HMAC secret for the admin session cookie
  // Set to "true" to enable the API-token login fallback. It is opt-in so
  // production deployments default to Sign in with Apple only.
  ADMIN_API_TOKEN_LOGIN?: string;

  // Optional iOS app login. When enabled, the app can exchange a native
  // Sign in with Apple identity token for a tenant API token.
  APPLE_APP_LOGIN_ENABLED?: string;       // set to "true" to enable
  APPLE_APP_SIGN_IN_CLIENT_ID?: string;   // native app bundle id, e.g. com.example.zerozerowidget

  // Master kill switch for the cross-tenant sharing feature. Any value other
  // than "true" disables every /v1/shares/* route, the ?include=shared
  // expansion on cards/activities, and recipient fanout in widget/Live
  // Activity pushes.
  SHARING_ENABLED?: string;
}
