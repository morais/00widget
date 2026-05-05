import { z } from "zod";

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

export const ActionRoleSchema = z.enum(["normal", "destructive"]).catch("normal");

export const ActionDefinitionSchema = z.object({
  id: z.string().min(1),
  label: z.string().min(1),
  role: ActionRoleSchema.default("normal"),
  confirm: z.boolean().default(false),
  payload: z.record(z.string(), z.string()).optional(),
});

export const DashboardItemSchema = z.object({
  id: z.string().min(1),
  title: z.string().min(1),
  subtitle: z.string().optional(),
  value: z.string().optional(),
  unit: z.string().optional(),
  status: DashboardStatusSchema.optional(),
});

const IsoDate = z.string().refine((s) => !Number.isNaN(Date.parse(s)), {
  message: "must be an ISO-8601 date",
});

export const SharedByInfoSchema = z.object({
  ownerEmail: z.string(),
  shareId: z.string(),
});

export const DashboardCardSchema = z.object({
  id: z.string().min(1),
  template: DashboardTemplateSchema,
  title: z.string().min(1),
  subtitle: z.string().optional(),
  value: z.string().optional(),
  unit: z.string().optional(),
  status: DashboardStatusSchema.default("unknown"),
  icon: z.string().optional(),
  updatedAt: IsoDate.optional(),
  staleAfter: IsoDate.optional(),
  deepLink: z.string().url().optional(),
  items: z.array(DashboardItemSchema).optional(),
  actions: z.array(ActionDefinitionSchema).optional(),
  // Set on cards returned via ?include=shared. Not persisted; not accepted on
  // upsert (zod will strip it because we don't .strict()).
  sharedBy: SharedByInfoSchema.optional(),
});

export const LiveActivityKindSchema = z
  .enum(["generic", "progress", "charging", "appliance", "job", "timer"])
  .catch("generic");

export const RegisterDeviceSchema = z.object({
  deviceId: z.string().min(1),
  apnsDeviceToken: z.string().optional(),
  appVersion: z.string().default("0.0"),
  platform: z.string().default("ios"),
});

export const RegisterWidgetPushTokenSchema = z.object({
  deviceId: z.string().min(1),
  widgetKind: z.string().min(1),
  widgetPushToken: z.string().min(1),
});

export const RegisterLiveActivitySchema = z.object({
  deviceId: z.string().min(1),
  localActivityId: z.string().min(1),
  externalActivityId: z.string().min(1),
  kind: LiveActivityKindSchema,
  pushToken: z.string().min(1),
});

export const RegisterLiveActivityStartTokenSchema = z.object({
  deviceId: z.string().min(1),
  attributesType: z.string().min(1),
  pushToken: z.string().min(1),
});

export const StartLiveActivitySchema = z.object({
  externalActivityId: z.string().min(1),
  kind: LiveActivityKindSchema,
  title: z.string().min(1),
  subtitle: z.string().optional(),
  state: z.string().min(1),
  icon: z.string().optional(),
  value: z.string().optional(),
  unit: z.string().optional(),
  progress: z.number().min(0).max(1).optional(),
  endsAt: IsoDate.optional(),
  staleAt: IsoDate.optional(),
  // Surfaced as aps.relevance-score on the APNs payload — Smart Stack on
  // iPhone and Apple Watch ranks Live Activities by this. Range is 0+;
  // larger wins. ActivityKit clamps/normalizes; we just pass through.
  relevanceScore: z.number().min(0).optional(),
  deepLink: z.string().url().optional(),
});

export const UpdateLiveActivitySchema = z.object({
  externalActivityId: z.string().min(1),
  state: z.string().optional(),
  title: z.string().optional(),
  subtitle: z.string().optional(),
  icon: z.string().optional(),
  value: z.string().optional(),
  unit: z.string().optional(),
  progress: z.number().min(0).max(1).optional(),
  endsAt: IsoDate.optional(),
  staleAt: IsoDate.optional(),
  relevanceScore: z.number().min(0).optional(),
  alert: z
    .object({
      title: z.string(),
      body: z.string().optional(),
    })
    .optional(),
});

export const EndLiveActivitySchema = z.object({
  externalActivityId: z.string().min(1),
  finalTitle: z.string().optional(),
  finalSubtitle: z.string().optional(),
  finalState: z.string().optional(),
  dismissalDate: IsoDate.optional(),
});

export const RunActionSchema = z.object({
  source: z.string().default("widget"),
  context: z
    .object({
      cardId: z.string().optional(),
    })
    .optional(),
});

export const WebhookIntegrationSchema = z.object({
  url: z.string().url(),
  rotateSecret: z.boolean().default(false),
});

export const ShareResourceKindSchema = z.enum(["card", "activity_kind"]);

export const ShareStatusSchema = z.enum(["pending", "accepted", "revoked", "declined"]);

export const CreateShareSchema = z.object({
  recipientEmail: z.string().email(),
  resourceKind: ShareResourceKindSchema,
  resourceId: z.string().min(1),
});

export type DashboardCard = z.infer<typeof DashboardCardSchema>;
export type DashboardItem = z.infer<typeof DashboardItemSchema>;
export type ActionDefinition = z.infer<typeof ActionDefinitionSchema>;
export type RegisterDevice = z.infer<typeof RegisterDeviceSchema>;
export type RegisterWidgetPushToken = z.infer<typeof RegisterWidgetPushTokenSchema>;
export type RegisterLiveActivity = z.infer<typeof RegisterLiveActivitySchema>;
export type RegisterLiveActivityStartToken = z.infer<typeof RegisterLiveActivityStartTokenSchema>;
export type StartLiveActivity = z.infer<typeof StartLiveActivitySchema>;
export type UpdateLiveActivity = z.infer<typeof UpdateLiveActivitySchema>;
export type EndLiveActivity = z.infer<typeof EndLiveActivitySchema>;
export type RunAction = z.infer<typeof RunActionSchema>;
export type WebhookIntegration = z.infer<typeof WebhookIntegrationSchema>;
export type ShareResourceKind = z.infer<typeof ShareResourceKindSchema>;
export type ShareStatus = z.infer<typeof ShareStatusSchema>;
export type CreateShareRequest = z.infer<typeof CreateShareSchema>;

export interface Env {
  ZW_DB: D1Database;
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
  // Set to "false" to disable the API-token login fallback. Any other value
  // (or unset) keeps it enabled. Useful while waiting for an Apple Developer
  // account; flip to "false" once Sign in with Apple is set up.
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
