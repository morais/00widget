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
  activityInstanceId: 64,
  activityState: 120,
  liveActivityItemCount: 6,
  liveActivityRecoveryCount: 8,
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

const ActionDefinitionFields = {
  id: IdString,
  label: z.string().min(1).max(FieldLimits.actionLabel),
  role: ActionRoleSchema.default("normal"),
  confirm: z.boolean().default(false),
};

// Public action shape returned to apps, widgets, and share recipients. Runtime
// payloads are deliberately absent; they live in server-only storage.
export const ActionDefinitionSchema = z.object(ActionDefinitionFields);

// Write-only action shape accepted from publishers. The storage layer extracts
// payload before persisting the public card JSON.
export const ActionDefinitionInputSchema = z.object({
  ...ActionDefinitionFields,
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

const DashboardCardFields = {
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
};

export const DashboardCardSchema = z.object({
  ...DashboardCardFields,
  actions: z.array(ActionDefinitionSchema).max(FieldLimits.actionCount).optional(),
  // Set only on cards returned via ?include=shared.
  sharedBy: SharedByInfoSchema.optional(),
});

export const DashboardCardInputSchema = z.object({
  ...DashboardCardFields,
  actions: z.array(ActionDefinitionInputSchema).max(FieldLimits.actionCount).optional(),
});

export const BatchUpsertCardsSchema = z
  .object({
    cards: z
      .array(DashboardCardInputSchema)
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

export const LiveActivityItemSchema = z.object({
  id: IdString,
  title: TitleString,
  subtitle: OptionalSubtitleString,
  icon: OptionalIconString,
  value: OptionalValueString,
  unit: OptionalUnitString,
  progress: z.number().min(0).max(1).optional(),
  status: DashboardStatusSchema.optional(),
});

const LiveActivityItemsSchema = z
  .array(LiveActivityItemSchema)
  .max(FieldLimits.liveActivityItemCount)
  .superRefine((items, ctx) => {
    const seen = new Set<string>();
    for (const [index, item] of items.entries()) {
      if (seen.has(item.id)) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          path: [index, "id"],
          message: "item ids must be unique",
        });
      }
      seen.add(item.id);
    }
  });

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
  // Optional only for registrations from pre-instance-ID app builds. The
  // server accepts that fallback solely when one target matches unambiguously.
  activityInstanceId: z.string().min(1).max(FieldLimits.activityInstanceId).optional(),
  externalActivityId: z.string().min(1).max(FieldLimits.externalActivityId),
  kind: LiveActivityKindSchema,
  pushToken: PushTokenString,
});

export const RegisterLiveActivityStartTokenSchema = z.object({
  deviceId: z.string().min(1).max(FieldLimits.deviceId),
  attributesType: z.string().min(1).max(FieldLimits.attributesType),
  pushToken: PushTokenString,
});

export const RecoverLiveActivitiesSchema = z.object({
  deviceId: z.string().min(1).max(FieldLimits.deviceId),
  activityInstanceIds: z
    .array(z.string().min(1).max(FieldLimits.activityInstanceId))
    .min(1)
    .max(FieldLimits.liveActivityRecoveryCount)
    .refine((ids) => new Set(ids).size === ids.length, {
      message: "activityInstanceIds must be unique",
    }),
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
  items: LiveActivityItemsSchema.optional(),
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
  items: LiveActivityItemsSchema.optional(),
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
  activityInstanceId: z.string().min(1).max(FieldLimits.activityInstanceId),
  externalActivityId: z.string().min(1).max(FieldLimits.externalActivityId),
  kind: LiveActivityKindSchema,
  title: TitleString,
  subtitle: OptionalSubtitleString,
  state: z.string().min(1).max(FieldLimits.activityState),
  icon: OptionalIconString,
  value: OptionalValueString,
  unit: OptionalUnitString,
  progress: z.number().min(0).max(1).optional(),
  items: LiveActivityItemsSchema.optional(),
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
// it rejects literal private/loopback/link-local IPs (including IPv6 forms that
// embed one, such as ::ffff:127.0.0.1) and the `localhost`/`.local` names, but
// does not resolve DNS, so a public hostname that resolves to an
// internal IP (or a DNS-rebind attack) will pass this filter. We rely on the
// Cloudflare Workers runtime to gate the actual fetch — Workers have no
// reachable private network and no cloud metadata endpoint — and on tenant
// authentication to limit who can configure a webhook in the first place.
// Re-evaluate this trade-off if this code ever runs outside Workers.
function isBlockedWebhookHostname(hostname: string): boolean {
  const host = hostname.toLowerCase().replace(/^\[|\]$/g, "").replace(/\.$/, "");
  if (host === "localhost" || host.endsWith(".localhost") || host.endsWith(".local")) {
    return true;
  }
  // Literal addresses are judged numerically below. The WHATWG URL parser has
  // already canonicalized the legacy IPv4 spellings for us — `2130706433`,
  // `0x7f000001`, `0177.0.0.1`, and `127.1` all arrive here as `127.0.0.1`.
  if (isPrivateIpv4(host)) return true;
  if (isBlockedIpv6(host)) return true;
  return false;
}

function ipv4Octets(host: string): number[] | null {
  const parts = host.split(".");
  if (parts.length !== 4) return null;
  const nums = parts.map((part) => Number(part));
  if (nums.some((n, i) => !Number.isInteger(n) || n < 0 || n > 255 || String(n) !== parts[i])) {
    return null;
  }
  return nums;
}

function isPrivateIpv4(host: string): boolean {
  const octets = ipv4Octets(host);
  return octets ? isPrivateIpv4Octets(octets) : false;
}

function isPrivateIpv4Octets([a, b]: number[]): boolean {
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
  const groups = parseIpv6(host);
  if (!groups) return false;
  // Unspecified (::) and loopback (::1).
  if (groups.slice(0, 7).every((group) => group === 0) && groups[7] <= 1) return true;
  // Unique local (fc00::/7) and link-local (fe80::/10).
  if ((groups[0] & 0xfe00) === 0xfc00) return true;
  if ((groups[0] & 0xffc0) === 0xfe80) return true;
  // An address that embeds an IPv4 destination reaches whatever that IPv4
  // reaches, so judge it by the embedded address.
  const embedded = embeddedIpv4(groups);
  return embedded ? isPrivateIpv4Octets(embedded) : false;
}

/// Parses an IPv6 host into its eight 16-bit groups, or null if `host` isn't
/// one. Text matching is not enough here: the URL parser compresses IPv6 hosts,
/// so `::ffff:127.0.0.1` reaches this code as `::ffff:7f00:1`.
function parseIpv6(host: string): number[] | null {
  if (!host.includes(":")) return null;
  const halves = host.split("::");
  if (halves.length > 2) return null;

  const toGroups = (part: string): number[] | null => {
    if (!part) return [];
    const pieces = part.split(":");
    const groups: number[] = [];
    for (const [index, piece] of pieces.entries()) {
      // A trailing dotted quad (::ffff:127.0.0.1) fills the last two groups.
      if (index === pieces.length - 1 && piece.includes(".")) {
        const octets = ipv4Octets(piece);
        if (!octets) return null;
        groups.push((octets[0] << 8) | octets[1], (octets[2] << 8) | octets[3]);
        continue;
      }
      if (!/^[0-9a-f]{1,4}$/.test(piece)) return null;
      groups.push(parseInt(piece, 16));
    }
    return groups;
  };

  const head = toGroups(halves[0]);
  const tail = halves.length === 2 ? toGroups(halves[1]) : [];
  if (!head || !tail) return null;
  if (halves.length === 1) return head.length === 8 ? head : null;
  const elided = 8 - head.length - tail.length;
  if (elided < 1) return null;
  return [...head, ...new Array<number>(elided).fill(0), ...tail];
}

function embeddedIpv4(groups: number[]): number[] | null {
  const octets = [groups[6] >> 8, groups[6] & 0xff, groups[7] >> 8, groups[7] & 0xff];
  const zeroPrefix = groups.slice(0, 5).every((group) => group === 0);
  // ::ffff:a.b.c.d (v4-mapped) and the deprecated ::a.b.c.d (v4-compatible).
  if (zeroPrefix && (groups[5] === 0xffff || groups[5] === 0)) return octets;
  // 64:ff9b::a.b.c.d — the well-known NAT64 prefix (RFC 6052).
  if (groups[0] === 0x64 && groups[1] === 0xff9b && groups.slice(2, 6).every((g) => g === 0)) {
    return octets;
  }
  return null;
}

export const ShareResourceKindSchema = z.enum(["card", "activity_kind"]);

export const ShareStatusSchema = z.enum(["pending", "accepted", "revoked", "declined"]);

export const CreateShareSchema = z.object({
  recipientEmail: z.email().max(FieldLimits.email),
  resourceKind: ShareResourceKindSchema,
  resourceId: z.string().min(1).max(FieldLimits.externalActivityId),
});

export type DashboardCard = z.infer<typeof DashboardCardSchema>;
export type DashboardCardInput = z.infer<typeof DashboardCardInputSchema>;
export type BatchUpsertCards = z.infer<typeof BatchUpsertCardsSchema>;
export type DashboardItem = z.infer<typeof DashboardItemSchema>;
export type ActionDefinition = z.infer<typeof ActionDefinitionSchema>;
export type ActionDefinitionInput = z.infer<typeof ActionDefinitionInputSchema>;
export type ActionPayload = z.infer<typeof ActionPayloadSchema>;
export type RegisterDevice = z.infer<typeof RegisterDeviceSchema>;
export type RegisterWidgetPushToken = z.infer<typeof RegisterWidgetPushTokenSchema>;
export type RegisterLiveActivity = z.infer<typeof RegisterLiveActivitySchema>;
export type RegisterLiveActivityStartToken = z.infer<typeof RegisterLiveActivityStartTokenSchema>;
export type RecoverLiveActivities = z.infer<typeof RecoverLiveActivitiesSchema>;
export type CountdownGranularity = z.infer<typeof CountdownGranularitySchema>;
export type StartLiveActivity = z.infer<typeof StartLiveActivitySchema>;
export type UpdateLiveActivity = z.infer<typeof UpdateLiveActivitySchema>;
export type LiveActivityItem = z.infer<typeof LiveActivityItemSchema>;
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
  AUTH_SOURCE_LIMITER: RateLimit;
  AUTH_TOKEN_LIMITER: RateLimit;
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

  // Associated domains. `<TeamID>.<bundle id>`, e.g.
  // ABCDE12345.com.example.zerozerowidget. Leaving APPLE_APP_ID unset makes
  // /.well-known/apple-app-site-association 404, which is the right answer for
  // a deployment with no app attached to it.
  APPLE_APP_ID?: string;
  APPLE_APP_CLIP_ID?: string;           // `<TeamID>.<bundle id>.Clip`, once a clip target exists

  // Optional operator alert when self-service signup creates a new tenant.
  // Both must be present or nothing is sent, so the default deployment needs no
  // Email Routing setup. Worth enabling wherever APPLE_APP_LOGIN_ENABLED is
  // "true", since tenant creation is otherwise silent.
  SIGNUP_ALERTS?: SendEmail;              // [[send_email]] binding in wrangler.toml
  SIGNUP_ALERT_TO?: string;               // recipient; the binding's verified destination
  SIGNUP_ALERT_FROM?: string;             // optional sender on an Email Routing domain
}
