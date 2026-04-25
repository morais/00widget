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

export const DashboardTemplateSchema = z
  .enum(["metric", "status", "progress", "timer", "list", "action"])
  .catch("status");

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

export const StartLiveActivitySchema = z.object({
  externalActivityId: z.string().min(1),
  kind: LiveActivityKindSchema,
  title: z.string().min(1),
  subtitle: z.string().optional(),
  state: z.string().min(1),
  value: z.string().optional(),
  unit: z.string().optional(),
  progress: z.number().min(0).max(1).optional(),
  staleAt: IsoDate.optional(),
  deepLink: z.string().url().optional(),
});

export const UpdateLiveActivitySchema = z.object({
  externalActivityId: z.string().min(1),
  state: z.string().optional(),
  title: z.string().optional(),
  subtitle: z.string().optional(),
  value: z.string().optional(),
  unit: z.string().optional(),
  progress: z.number().min(0).max(1).optional(),
  staleAt: IsoDate.optional(),
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

export type DashboardCard = z.infer<typeof DashboardCardSchema>;
export type DashboardItem = z.infer<typeof DashboardItemSchema>;
export type ActionDefinition = z.infer<typeof ActionDefinitionSchema>;
export type RegisterDevice = z.infer<typeof RegisterDeviceSchema>;
export type RegisterWidgetPushToken = z.infer<typeof RegisterWidgetPushTokenSchema>;
export type RegisterLiveActivity = z.infer<typeof RegisterLiveActivitySchema>;
export type StartLiveActivity = z.infer<typeof StartLiveActivitySchema>;
export type UpdateLiveActivity = z.infer<typeof UpdateLiveActivitySchema>;
export type EndLiveActivity = z.infer<typeof EndLiveActivitySchema>;
export type RunAction = z.infer<typeof RunActionSchema>;

export interface Env {
  ZW_KV: KVNamespace;
  API_KEYS: string;
  APNS_TEAM_ID?: string;
  APNS_KEY_ID?: string;
  APNS_PRIVATE_KEY?: string;
  APNS_BUNDLE_ID?: string;
  APNS_ENV?: "sandbox" | "production";
}
