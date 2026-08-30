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
  guestLink: 4 * KiB,
  appleLogin: 16 * KiB,
  // One JSON-RPC envelope on the MCP endpoint. It has to clear the largest
  // body any tool forwards (a card batch) plus the wrapper around it.
  mcpRpc: 160 * KiB,
  // StoreKit hands over every current entitlement at once, and each is a JWS
  // carrying a full certificate chain — a few KiB apiece.
  subscriptionVerify: 128 * KiB,
  appleNotification: 64 * KiB,
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
  chartPointCount: 60,
  chartSeriesCount: 4,
  chartSeriesLabel: 60,
  chartAxisLabel: 40,
  briefingSectionCount: 8,
  briefingLabel: 60,
  briefingText: 500,
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

// Card and action ids are addressed as URL path segments — `/v1/cards/<id>`,
// `/v1/actions/<id>/run` — so they have to survive that round trip. They did
// not: any id was accepted, and one containing a `/` produced a card that
// could be created and then never read or deleted through the API, because the
// route pattern is `([^/]+)`. A space was enough to strand one too.
//
// Constrained on the way in only. Stored rows keep the permissive shape so a
// card written before this rule still loads, and the path decoding added
// alongside it means a percent-encoded id can now reach one to delete it.
const URL_SAFE_ID = /^[A-Za-z0-9._:-]+$/;
const URL_SAFE_ID_MESSAGE =
  "must contain only letters, digits, and . _ : - (it is used as a URL path segment)";
const CardIdInputString = CardIdString.regex(URL_SAFE_ID, URL_SAFE_ID_MESSAGE);
const ActionIdInputString = IdString.regex(URL_SAFE_ID, URL_SAFE_ID_MESSAGE);
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

export const DashboardTemplateSchema = z.enum([
  "summary",
  "progress",
  "list",
  "action",
  "chart",
  "history",
  "breakdown",
  "briefing",
]);

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
  id: IdString.describe(
    "Stable id for the button. It is the `/v1/actions/<id>/run` path segment "
    + "and is echoed back in the webhook delivery.",
  ),
  label: z.string().min(1).max(FieldLimits.actionLabel).describe(
    "What the button says. Short enough for a widget: \"Boost 1h\", \"Retry\".",
  ),
  role: ActionRoleSchema.default("normal").describe(
    "`destructive` marks the button as dangerous and stops it running from a "
    + "widget; it routes through the iOS app for confirmation instead.",
  ),
  confirm: z.boolean().default(false).describe(
    "Ask the person before running. Also stops the button running from a "
    + "widget, for the same reason `role: destructive` does.",
  ),
};

// Public action shape returned to apps, widgets, and share recipients. Runtime
// payloads are deliberately absent; they live in server-only storage.
export const ActionDefinitionSchema = z.object(ActionDefinitionFields);

// Write-only action shape accepted from publishers. The storage layer extracts
// payload before persisting the public card JSON.
export const ActionDefinitionInputSchema = z.object({
  ...ActionDefinitionFields,
  id: ActionIdInputString,
  payload: ActionPayloadSchema.optional().describe(
    "Private context delivered to your webhook when the button is pressed. "
    + "Write-only: it is stripped from the stored card and never returned by "
    + "any read, shared card, or device cache.",
  ),
});

export const DashboardItemSchema = z.object({
  id: IdString.describe("Stable id for this row, unique within the card."),
  title: TitleString.describe("The row's label."),
  subtitle: OptionalSubtitleString.describe("A second line under the row's title."),
  value: OptionalValueString.describe(
    "The row's reading, as a display string already formatted for a person.",
  ),
  unit: OptionalUnitString.describe("Unit shown after `value`."),
  status: DashboardStatusSchema.optional().describe(
    "Colours the row. In a `history` card it is the entire content: each item is "
    + "one past outcome and only its status is drawn.",
  ),
  deepLink: OptionalDeepLink.describe(
    "HTTPS URL opened when this row is tapped, instead of the card's own "
    + "`deepLink`. Only medium and large Home Screen widgets can address a "
    + "single row; everywhere smaller the whole card is one tap target and the "
    + "card's link is used.",
  ),
  // The row's magnitude, for templates that draw items rather than list them.
  // `value` cannot serve: it is a display string ("12.40", "3m 51s", "Rinse")
  // and parsing it back into a number would guess at locale and format.
  amount: z.number().optional().describe(
    "The row's magnitude, used to draw it: ranked bars in a `list` (measured "
    + "against the largest row) or proportional segments in a `breakdown` "
    + "(measured against the total, so never send percentages). Send it "
    + "alongside `value`, not instead of it — `value` is the label.",
  ),
});

export const DashboardBriefingSectionSchema = z.object({
  id: IdString.describe(
    "Stable id for this detail. Order sections from most important to least: "
    + "smaller surfaces show only a prefix.",
  ),
  label: z.string().max(FieldLimits.briefingLabel).optional().describe(
    "Optional short heading such as Cause, Impact, or Next.",
  ),
  text: z.string().min(1).max(FieldLimits.briefingText).describe(
    "One self-contained plain-text detail. Do not send Markdown. Make it useful "
    + "without relying on a later section, because smaller widgets may stop here.",
  ),
});

export const DashboardBriefingSchema = z.object({
  sections: z.array(DashboardBriefingSectionSchema)
    .min(1)
    .max(FieldLimits.briefingSectionCount)
    .describe(
      "Progressive details, most important first. The card's value and subtitle "
      + "are the compact conclusion and old-client fallback.",
    ),
});

// "delta" is "bar" anchored at zero rather than at the bottom of the range:
// signed values grow up or down from a zero rule. Net import/export, commits
// added/removed, spend vs refund.
export const ChartStyleSchema = z.enum(["line", "bar", "delta"]);
export const ChartStackingSchema = z.enum(["stacked", "grouped"]);

export const DashboardChartSeriesSchema = z.object({
  id: IdString.describe("Stable series id, used to keep its color consistent."),
  label: z.string().min(1).max(FieldLimits.chartSeriesLabel).describe(
    "Short legend label.",
  ),
  points: z.array(z.number().min(0)).min(2).max(FieldLimits.chartPointCount).describe(
    "Non-negative values aligned one-for-one with every other series and labels.",
  ),
});

// The numeric series behind a `chart` card. Points are plotted evenly spaced in
// the order given, oldest first; there are no timestamps, because a widget this
// small has no room for an x axis and the renderer would ignore them.
//
// `min`/`max` pin the y range. Without them the renderer scales to the series,
// which makes every card use its full height but also makes a flat-but-noisy
// series look dramatic. Publish an explicit range whenever the absolute scale
// is the point (a percentage, a 0-100 score).
const DashboardChartObjectSchema = z
  .object({
    points: z.array(z.number()).min(2).max(FieldLimits.chartPointCount).describe(
      "2-60 values, oldest first, plotted evenly spaced. There are no "
      + "timestamps: send a fixed rolling window. The small surfaces — Lock "
      + "Screen, small widget, grid cells — average a long series down to what "
      + "they can draw, so the window you send is always the window shown; "
      + "send the resolution the data actually has.",
    ),
    min: z.number().optional().describe(
      "Pins the bottom of the plot. Without a range the plot scales to the "
      + "series, so a flat-but-noisy one looks dramatic. Send at least `min: 0` "
      + "whenever the absolute scale is the point.",
    ),
    max: z.number().optional().describe("Pins the top of the plot."),
    // A target, budget, or threshold, drawn as a dashed rule across the plot.
    // When the axis is not pinned it widens to keep the rule visible; when it
    // is pinned and the rule falls outside, the renderer omits it rather than
    // clamping it to an edge and stating something the data does not.
    reference: z.number().optional().describe(
      "A target, budget, SLO or threshold, drawn as a dashed rule across the "
      + "plot. Usually the difference between a trend you can read and one you "
      + "can act on, because above-or-below needs no axis labels. The rule has "
      + "no numeric label; when its exact value matters, lead the card's short "
      + "`subtitle` with its formatted meaning and value.",
    ),
    style: ChartStyleSchema.default("line").describe(
      "`line` is a sparkline with a soft area fill; `bar` grows every bar from "
      + "the bottom of the range; `delta` anchors at zero instead, so signed "
      + "values grow up or down from a zero rule.",
    ),
    labels: z.array(z.string().max(FieldLimits.chartAxisLabel))
      .min(2)
      .max(FieldLimits.chartPointCount)
      .optional()
      .describe(
        "Optional category labels aligned with points. Small surfaces omit them; "
        + "large widgets and detail views show a readable subset.",
      ),
    series: z.array(DashboardChartSeriesSchema)
      .min(2)
      .max(FieldLimits.chartSeriesCount)
      .optional()
      .describe(
        "Two to four series for stacked or grouped vertical bars. The server "
        + "derives legacy points as their totals for older clients.",
      ),
    stacking: ChartStackingSchema.default("stacked").describe(
      "How multiple bar series share each category: stacked into one column or grouped side by side.",
    ),
  })
  .superRefine((chart, ctx) => {
    if (chart.min !== undefined && chart.max !== undefined && chart.min >= chart.max) {
      ctx.addIssue({ code: "custom", message: "min must be less than max" });
    }
    if (chart.labels && chart.labels.length !== chart.points.length) {
      ctx.addIssue({ code: "custom", path: ["labels"], message: "must match points length" });
    }
    if (chart.series) {
      if (chart.style !== "bar") {
        ctx.addIssue({ code: "custom", path: ["style"], message: "multiple series require bar style" });
      }
      const ids = new Set(chart.series.map((entry) => entry.id));
      if (ids.size !== chart.series.length) {
        ctx.addIssue({ code: "custom", path: ["series"], message: "series ids must be unique" });
      }
      chart.series.forEach((entry, index) => {
        if (entry.points.length !== chart.points.length) {
          ctx.addIssue({
            code: "custom",
            path: ["series", index, "points"],
            message: "must match every other series length",
          });
        }
      });
    }
  });

// `points` is the compatibility bridge. A producer sends only the richer
// series; before validation and storage the server derives one total per
// category. Builds that predate `series` ignore it and still draw those totals.
export const DashboardChartSchema = z.preprocess((input) => {
  if (!input || typeof input !== "object" || Array.isArray(input)) return input;
  const chart = input as Record<string, unknown>;
  const rawSeries = chart.series;
  if (!Array.isArray(rawSeries) || rawSeries.length === 0) return input;
  const pointArrays = rawSeries.map((entry) => {
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) return null;
    return (entry as Record<string, unknown>).points;
  });
  if (!pointArrays.every(Array.isArray)) return input;
  const count = (pointArrays[0] as unknown[]).length;
  if (!pointArrays.every((points) => (points as unknown[]).length === count)) return input;
  if (!pointArrays.every((points) => (points as unknown[]).every((value) => typeof value === "number"))) {
    return input;
  }
  const points = Array.from({ length: count }, (_, index) =>
    pointArrays.reduce((total, values) => total + Number((values as number[])[index]), 0));
  return {
    ...chart,
    points,
    style: chart.style ?? "bar",
    stacking: chart.stacking ?? "stacked",
    min: chart.min ?? 0,
  };
}, DashboardChartObjectSchema);

// Exactly what every consumer of these values can parse, which is narrower
// than what `Date.parse` accepts. iOS reads dates with `ISO8601DateFormatter`
// under `[.withInternetDateTime]` (plus optional fractional seconds), so
// seconds and a UTC offset are both mandatory there. Validating with
// `Date.parse` alone accepted `"2026-04-26"` and `"April 26 2026"`, stored
// them, echoed them back on read, and then decoded them to nil on the device —
// a card that simply never went stale, with a 200 at every step.
const ISO_8601_INSTANT = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})$/;

const IsoDate = z
  .string()
  .regex(
    ISO_8601_INSTANT,
    "must be an ISO-8601 timestamp with seconds and a UTC offset, e.g. 2026-04-26T18:45:00Z",
  )
  // The pattern admits 2026-13-45T99:99:99Z; this rejects what it cannot mean.
  .refine((s) => !Number.isNaN(Date.parse(s)), { message: "must be a real date" });

// The permissive shape, for values read back out of storage rather than
// accepted from a caller. Cards are re-validated on every read, so a row
// written before the rule above tightened must still load: one legacy date
// must not 500 the whole list. Nothing writes through this.
const StoredIsoDate = z.string().refine((s) => !Number.isNaN(Date.parse(s)), {
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

/// An address this server will accept from a caller or from an identity
/// provider, as opposed to one already stored.
///
/// Worth having in one place because an owner email is not only displayed: it
/// joins an Apple sign-in to a tenant, and it is interpolated into RFC 5322
/// headers by the signup alert. Anything carrying a control character is a
/// header injection waiting for a deployment that has mail configured.
export const EmailString = z.email().max(FieldLimits.email);

export function isValidEmail(value: string | null | undefined): boolean {
  return EmailString.safeParse(value ?? "").success;
}

export const SharedByInfoSchema = z.object({
  ownerEmail: z.string().max(FieldLimits.email),
  shareId: z.string().max(FieldLimits.id),
});

const DashboardCardFields = {
  id: CardIdString.describe(
    "Stable identity of the thing being shown, reused on every publish so the "
    + "card updates rather than duplicating. Never embed a timestamp or run id. "
    + "Namespace it if another integration might pick the same name.",
  ),
  template: DashboardTemplateSchema.describe(
    "How the card is drawn. Pick by the shape of the data, not the domain: "
    + "`summary` for one headline number or short state; `progress` for "
    + "something filling up; `list` for 2-6 things with their own values; "
    + "`action` for buttons; `chart` for one number moving over time; "
    + "`history` for a run of pass/fail outcomes; `breakdown` for a whole split "
    + "into parts; `briefing` for a conclusion followed by ordered prose. When "
    + "unsure, `summary` degrades best at every widget size.",
  ),
  title: TitleString.describe(
    "The name of the thing. It renders on one line at caption size, so keep it "
    + "short and stable — a value that moves belongs in `value`.",
  ),
  subtitle: OptionalSubtitleString.describe(
    "A short, single-line label under the title or value. It truncates rather "
    + "than wraps on widgets, so aim for about 40 characters, put essential "
    + "numbers and qualifiers first, and do not repeat the title. For a chart "
    + "whose `reference` matters, lead with its formatted meaning and value: "
    + "\"$300 baseline · Mar–Aug 2026\".",
  ),
  value: OptionalValueString.describe(
    "The headline, as a display string already formatted for a person: "
    + "\"3.2\", \"$338.99\", \"4m 12s\", \"Healthy\". It is never parsed "
    + "back into a number.",
  ),
  unit: OptionalUnitString.describe(
    "Suffix shown after `value`: kW, %, jobs. Prefixes such as currency symbols "
    + "belong in the formatted `value` instead; use `value: \"$338.99\"` and "
    + "omit `unit`, not `value: \"338.99\"` with `unit: \"$\"`.",
  ),
  status: DashboardStatusSchema.default("unknown").describe(
    "Drives the card's tint and badge on every surface. `good`/`warning`/"
    + "`critical` for health, `running`/`finished`/`paused`/`offline` for "
    + "lifecycle.",
  ),
  icon: OptionalIconString.describe(
    "SF Symbol name for the card: sun.max, bolt.car, flame, washer, creditcard.",
  ),
  statusIcon: OptionalIconString.describe(
    "A second SF Symbol for a runtime state that changes independently of what "
    + "the card is — bolt.fill while boosting, arrow.up while charging. Drawn "
    + "at every widget size, including grid cells.",
  ),
  // Where the card sits in every list the API returns. Ordering used to be
  // `ORDER BY id` alone, which made the dedupe key double as the sort key: a
  // producer could only promote a card by renaming it, and renaming it creates
  // a second card. Higher first, absent counts as 0, ties still broken by id so
  // the order stays stable for everything that sets nothing.
  priority: z.number().int().optional().describe(
    "Where this card sits among the tenant's cards. Higher comes first; absent "
    + "counts as 0 and ties break by `id`, which is the order everything had "
    + "before. It decides the order of `GET /v1/cards`, the app's dashboard, "
    + "and which cards fill a Home Screen grid widget that has not been "
    + "configured with specific ones.",
  ),
  // How full the thing is, 0-1. The `progress` template used to carry this in
  // `value`, parsed back out as a Double with anything above 1 read as a
  // percentage — so a progress card could draw a bar or show a headline number
  // but never both, and "3 of 12" could not be said at all. This is the field a
  // Live Activity has always had. `value` stays the display string.
  progress: z.number().min(0).max(1).optional().describe(
    "How full the thing is, 0-1, drawn as a bar. Required in practice by "
    + "`template: progress`, ignored where there is nowhere to draw it. Keep "
    + "`value` as the label, so the card can show both: \"184 of 240\".",
  ),
  updatedAt: IsoDate.optional().describe(
    "When this state was true, as an ISO-8601 instant with seconds and an "
    + "offset (2026-04-26T18:45:00Z). Omit it and the server stamps the time "
    + "the publish arrived.",
  ),
  staleAfter: IsoDate.optional().describe(
    "After this the widget dims the card into a 'stale' state so the reading "
    + "is visibly old. A hint only: nothing hides or deletes the card.",
  ),
  // When the thing this card is about is due. Rendered as a countdown the
  // device ticks on its own, which is the only way a card can hold a correct
  // relative time: a widget reloads at most once every 30 minutes, so a
  // republished "12 min left" is wrong for most of the time it is on screen.
  deadline: IsoDate.optional().describe(
    "When the thing this card is about is due, drawn as a countdown the device "
    + "ticks locally. Publish a date here rather than writing the remaining "
    + "time into `value`: a widget reloads at most twice an hour, so a "
    + "republished string is wrong for most of the time it is on screen.",
  ),
  deepLink: OptionalDeepLink.describe(
    "HTTPS URL opened when the card is tapped. Point it at the dashboard or "
    + "detail page this card summarises.",
  ),
  items: z.array(DashboardItemSchema).max(FieldLimits.itemCount).optional().describe(
    "Rows. A `list` shows them as rows, ranked as bars when they carry an "
    + "`amount`; a `history` draws their `status` as pips, oldest first; a "
    + "`breakdown` splits one bar by their `amount`.",
  ),
  chart: DashboardChartSchema.optional().describe(
    "The series behind a `chart` card. Republish the whole window every time — "
    + "nothing is appended and no history is kept.",
  ),
  briefing: DashboardBriefingSchema.optional().describe(
    "Ordered prose behind a `briefing` card. Keep `value` as the compact "
    + "conclusion and `subtitle` as its first explanation: old clients render "
    + "the unknown template as a summary and still show both.",
  ),
};

// The stored/read shape. Dates are the permissive variant here: `storage.ts`
// re-validates every card it loads, and a row written under the old rule has
// to keep rendering rather than failing the read.
export const DashboardCardSchema = z.object({
  ...DashboardCardFields,
  updatedAt: StoredIsoDate.optional(),
  staleAfter: StoredIsoDate.optional(),
  deadline: StoredIsoDate.optional(),
  actions: z.array(ActionDefinitionSchema).max(FieldLimits.actionCount).optional(),
  // Set only on cards returned via ?include=shared.
  sharedBy: SharedByInfoSchema.optional(),
});

export const DashboardCardInputSchema = z.object({
  ...DashboardCardFields,
  id: CardIdInputString.describe(
    "Stable identity of the thing being shown, reused on every publish so the "
    + "card updates rather than duplicating. Never embed a timestamp or run id. "
    + "Letters, digits and . _ : - only, because it is also a URL path segment.",
  ),
  actions: z.array(ActionDefinitionInputSchema).max(FieldLimits.actionCount).optional().describe(
    "Buttons. They are not tied to `template: action` — any template can carry "
    + "them, so a `chart` card can plot a series and offer a Retry button. "
    + "`action` is simply the template whose whole point is the buttons, with no "
    + "visual of its own. How many are drawn depends on the surface: a small "
    + "widget shows 1, medium 2, large and extra-large 4, and the iOS app and "
    + "Apple TV show all of them; the Lock Screen accessories show none, and a "
    + "widget the operator has set to Compact density shows one fewer (none at "
    + "all on a small one). Order them most useful first, because the tail is "
    + "what gets cut. Only `role: normal` with `confirm: false` can run straight "
    + "from a widget; anything else routes through the iOS app "
    + "for confirmation. A press is delivered to the account's action webhook, "
    + "so one must already be registered at PUT /v1/integrations/webhook or "
    + "every press fails with a 409. That call needs the `webhook:manage` "
    + "scope, which an MCP credential does not have — the operator registers "
    + "the webhook with their API token, from whatever runs the endpoint.",
  ),
});

export const BatchUpsertCardsSchema = z
  .object({
    // Deleting what a snapshot no longer contains, scoped to a prefix the
    // producer owns. Without it there is no way to shrink: a producer that
    // stops reporting something, or renames its ids, leaves the old cards on
    // the operator's Home Screen forever, and only the operator can remove
    // them. Scoped rather than global because an account may carry cards from
    // several producers, and none of them may sweep the others away.
    replacePrefix: CardIdInputString
      .describe(
        "Delete this tenant's cards whose id starts with this prefix and that "
        + "are absent from `cards`. Use the namespace you already publish under "
        + "(\"myapp-\"), so one producer's snapshot can never remove another's "
        + "cards. Every card in the batch must start with it, which is what "
        + "stops a typo from deleting everything.",
      )
      .optional(),
    cards: z
      .array(DashboardCardInputSchema)
      .min(1)
      .max(FieldLimits.cardBatchCount)
      .describe(
        "Every card from one producer snapshot, sent together. Ids must be "
        + "unique within the batch. This is one coalesced widget-reload "
        + "decision instead of one per card, which is why it is preferred over "
        + "looping the single-card endpoint.",
      ),
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
      // A batch that deletes by prefix must be entirely inside that prefix.
      // Otherwise a mistyped `replacePrefix` still publishes every card and
      // then deletes a namespace nothing in the request belongs to — a
      // destructive no-op that looks like success.
      if (value.replacePrefix !== undefined && !card.id.startsWith(value.replacePrefix)) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          path: ["cards", index, "id"],
          message: `must start with replacePrefix "${value.replacePrefix}"`,
        });
      }
    }
  });

export const LiveActivityKindSchema = z
  .enum(["generic", "progress", "charging", "appliance", "job", "timer"])
  .catch("generic");

export const CountdownGranularitySchema = z.enum(["second", "minute"]);

export const LiveActivityItemSchema = z.object({
  id: IdString.describe("Stable id for this row, unique within the activity."),
  title: TitleString.describe("The row's label."),
  subtitle: OptionalSubtitleString.describe("A second line under the row's title."),
  icon: OptionalIconString.describe("SF Symbol name for this row."),
  statusIcon: OptionalIconString.describe(
    "A second SF Symbol for what this row is doing right now, drawn beside its "
    + "own icon — arrow.up while charging, pause.fill while held.",
  ),
  value: OptionalValueString.describe("The row's reading, as a display string."),
  unit: OptionalUnitString.describe("Unit shown after the row's `value`."),
  progress: z.number().min(0).max(1).optional().describe("This row's own progress, 0-1."),
  status: DashboardStatusSchema.optional().describe(
    "Rows with `finished` or `offline` are hidden, and the activity counts the "
    + "rest as its active total.",
  ),
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
    if (value.subscriptions.length === 0 && value.widgetPushToken) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ["widgetPushToken"],
        message: "omit widgetPushToken when clearing subscriptions",
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
  externalActivityId: z.string().min(1).max(FieldLimits.externalActivityId).describe(
    "Your own id for this run. It addresses the activity on every later update "
    + "and on the end call, so keep it until the end returns 2xx. Starting on an "
    + "id that is already running RESTARTS it: the running activity is ended and "
    + "a new one replaces it, which the user sees as one dismissing and another "
    + "animating in. That is how to change a frozen `title`, `kind` or "
    + "`deepLink`, and it is not something to do on a tick.",
  ),
  kind: LiveActivityKindSchema.describe(
    "Picks the default glyph when no `icon` is set: generic, progress, "
    + "charging, appliance, job, timer. Frozen once the activity starts.",
  ),
  title: TitleString.describe(
    "The name of the thing. FROZEN for the life of the activity — no update can "
    + "change what the Lock Screen shows, only a restart can. So it must never "
    + "carry a value that moves: \"CI build #1234\" and \"Dishwasher\" are titles, "
    + "\"42 min left\" and \"64% charged\" are not. Put those in `value`, "
    + "`progress` or `endsAt`.",
  ),
  subtitle: OptionalSubtitleString.describe("A line of prose under the title. Updatable."),
  state: z.string().min(1).max(FieldLimits.activityState).describe(
    "Free-form short text for where the run is up to — \"running\", \"Rinse\", "
    + "\"waiting for approval\". Rendered as text; no value has special meaning, "
    + "and setting it to \"finished\" does not end the activity.",
  ),
  icon: OptionalIconString.describe("SF Symbol name, overriding the one `kind` implies."),
  statusIcon: OptionalIconString.describe(
    "A second SF Symbol for what the activity is doing right now, drawn beside "
    + "the main one — bolt.fill while boosting, exclamationmark.triangle.fill "
    + "when something needs attention. Unlike `icon`, which says what the "
    + "activity IS, this says what it is DOING, so it is content state and "
    + "changes on every update.",
  ),
  value: OptionalValueString.describe(
    "The headline, as a display string. With `items`, an explicit value "
    + "outranks the derived active-item count.",
  ),
  unit: OptionalUnitString.describe("Unit shown after `value`."),
  progress: z.number().min(0).max(1).optional().describe(
    "Progress bar, 0-1. A `chart` outranks it for the space, and `items` "
    + "replace it entirely.",
  ),
  items: LiveActivityItemsSchema.optional().describe(
    "Up to 6 rows, for an activity that is several things at once — three "
    + "chargers, a queue of jobs, a set of checks. Rows REPLACE the progress "
    + "bar and SUPPRESS any `chart` on the Lock Screen and Dynamic Island, "
    + "silently and with no error, so send items or a chart but not both.",
  ),
  // Content state, so unlike a card's chart this one may change on every
  // update. It is the field that makes a Live Activity worth watching rather
  // than glancing at: the number is moving, and the plot says which way.
  chart: DashboardChartSchema.optional().describe(
    "A plot of the number this activity is about — watts climbing, queue depth "
    + "dropping. Send the whole window on every update. It outranks `progress` "
    + "for the space, and `items` suppress it entirely on the Lock Screen and "
    + "Dynamic Island.",
  ),
  endsAt: IsoDate.optional().describe(
    "When the run is expected to finish. iOS then renders a countdown from the "
    + "device clock, so you do not need to publish updates just to tick time "
    + "forward. Prefer this over server-ticked percentages.",
  ),
  countdownGranularity: CountdownGranularitySchema.optional().describe(
    "How the `endsAt` countdown reads. `second` (default) keeps the native "
    + "ticking clock; `minute` renders a rounded estimate like ~12 min and "
    + "updates locally at minute boundaries. Ignored without `endsAt`.",
  ),
  staleAt: IsoDate.optional().describe(
    "After this iOS renders the activity as out of date, so a run whose "
    + "producer has gone quiet says so instead of looking current. Send it on "
    + "every push, a little past when you next expect to publish. It is the "
    + "only thing that makes a stalled producer visible to the operator, and "
    + "it costs nothing when you do keep publishing.",
  ),
  // Surfaced as aps.relevance-score on the APNs payload — Smart Stack on
  // iPhone and Apple Watch ranks Live Activities by this. Range is 0+;
  // larger wins. ActivityKit clamps/normalizes; we just pass through.
  relevanceScore: z.number().min(0).optional().describe(
    "How this activity ranks against others in Smart Stack on the Lock Screen "
    + "and Apple Watch; higher wins, with no fixed ceiling. Start low on a long "
    + "run and raise it as the activity becomes urgent.",
  ),
  deepLink: OptionalDeepLink.describe(
    "HTTPS URL opened when the activity is tapped. FROZEN at start, like "
    + "`title` and `kind`.",
  ),
  alert: z
    .object({
      title: z.string().min(1).max(FieldLimits.alertTitle).describe("Banner headline."),
      body: z.string().max(FieldLimits.alertBody).optional().describe("Banner body."),
    })
    .optional()
    .describe(
      "Sends this one push as a visible notification. For state changes worth "
      + "interrupting someone for — finished, failed — and nothing else; it does "
      + "not rename the activity.",
    ),
});

// An update merges into the running activity's content state, so an omitted
// field keeps whatever is there. That left no way to *remove* one: an activity
// that had ever carried a `progress`, `chart`, or `endsAt` carried it for the
// rest of its life, so a job that finished early kept a countdown that had
// already run out, and a chart that stopped being the point kept winning the
// banner from `progress`.
//
// `null` clears. Omitted still keeps. `items` accepts `null` alongside the `[]`
// that already worked, so one rule covers every content-state field.
export const UpdateLiveActivitySchema = z.object({
  externalActivityId: z.string().min(1).max(FieldLimits.externalActivityId).describe(
    "The id you started the activity with.",
  ),
  state: z.string().min(1).max(FieldLimits.activityState).describe(
    "Where the run is up to now.",
  ).optional(),
  title: z.string().min(1).max(FieldLimits.title).optional().describe(
    "Accepted and stored, but it does NOT change the running activity: the "
    + "title is frozen when it starts. Leave it out of updates.",
  ),
  subtitle: z.string().max(FieldLimits.subtitle).nullish().describe(
    "New prose under the title. `null` removes it.",
  ),
  icon: z.string().max(FieldLimits.icon).nullish().describe(
    "New SF Symbol name. `null` falls back to the one `kind` implies.",
  ),
  statusIcon: z.string().max(FieldLimits.icon).nullish().describe(
    "New runtime glyph. `null` removes it — which is what an activity that has "
    + "stopped doing the thing should send.",
  ),
  value: z.string().max(FieldLimits.value).nullish().describe(
    "New headline display string. `null` removes it.",
  ),
  unit: z.string().max(FieldLimits.unit).nullish().describe("New unit. `null` removes it."),
  progress: z.number().min(0).max(1).nullish().describe(
    "New progress, 0-1. `null` removes the bar — which is what a run that has "
    + "finished should send.",
  ),
  items: LiveActivityItemsSchema.nullish().describe(
    "The complete row list, replacing what is there. `[]` or `null` returns the "
    + "activity to its top-level fields and lets a `chart` show again.",
  ),
  chart: DashboardChartSchema.nullish().describe(
    "The whole current window, replacing the last one. `null` removes the plot.",
  ),
  endsAt: IsoDate.nullish().describe(
    "A new expected finish. `null` removes the countdown, and takes "
    + "`countdownGranularity` with it.",
  ),
  countdownGranularity: CountdownGranularitySchema.nullish().describe(
    "How the countdown reads. Omitted, the activity keeps its current setting.",
  ),
  staleAt: IsoDate.nullish().describe(
    "New stale time. Send it on every update, a little past when you next "
    + "expect to publish, so the activity marks itself out of date if this is "
    + "the last update you send. `null` removes it, which leaves a stalled "
    + "activity looking current — only do that on the way to `end`.",
  ),
  relevanceScore: z.number().min(0).nullish().describe(
    "New Smart Stack ranking. Spike it on the finishing update so the wrist "
    + "surfaces it.",
  ),
  alert: z
    .object({
      title: z.string().min(1).max(FieldLimits.alertTitle).describe("Banner headline."),
      body: z.string().max(FieldLimits.alertBody).optional().describe("Banner body."),
    })
    .optional()
    .describe(
      "Sends this one push as a visible notification. For state changes worth "
      + "interrupting someone for — finished, failed — and nothing else; it does "
      + "not rename the activity.",
    ),
});

// Also a stored shape: `updateLiveActivity` re-parses the instance it loaded
// from D1 before writing the next one, so this takes the permissive dates for
// the same reason `DashboardCardSchema` does.
export const LiveActivitySessionSchema = z.object({
  activityInstanceId: z.string().min(1).max(FieldLimits.activityInstanceId),
  externalActivityId: z.string().min(1).max(FieldLimits.externalActivityId),
  kind: LiveActivityKindSchema,
  title: TitleString,
  subtitle: OptionalSubtitleString,
  state: z.string().min(1).max(FieldLimits.activityState),
  icon: OptionalIconString,
  statusIcon: OptionalIconString,
  value: OptionalValueString,
  unit: OptionalUnitString,
  progress: z.number().min(0).max(1).optional(),
  items: LiveActivityItemsSchema.optional(),
  chart: DashboardChartSchema.optional(),
  endsAt: StoredIsoDate.optional(),
  countdownGranularity: CountdownGranularitySchema.optional(),
  startedAt: StoredIsoDate.optional(),
  updatedAt: StoredIsoDate,
  staleAt: StoredIsoDate.optional(),
  relevanceScore: z.number().min(0).optional(),
  deepLink: OptionalDeepLink,
});

// No `finalTitle`: the title is an ActivityAttributes property, frozen when the
// activity starts, so nothing on the end push could apply it. The final frame is
// content state only.
export const EndLiveActivitySchema = z.object({
  externalActivityId: z.string().min(1).max(FieldLimits.externalActivityId).describe(
    "The id you started the activity with.",
  ),
  finalSubtitle: OptionalSubtitleString.describe(
    "What happened, on the last frame — \"passed in 4m 12s\". There is no "
    + "`finalTitle`, because the title is frozen, so say it here.",
  ),
  finalState: z.string().max(FieldLimits.activityState).optional().describe(
    "The last state text. Defaults to \"finished\".",
  ),
  dismissalDate: IsoDate.optional().describe(
    "Keeps the final frame on the Lock Screen until this time, within Apple's "
    + "four-hour window. Omitted, the activity is dismissed immediately.",
  ),
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
// it rejects literal private, loopback, link-local, carrier-grade-NAT,
// protocol-assignment, benchmarking, multicast and reserved addresses —
// including the IPv6 forms that embed one, such as ::ffff:127.0.0.1 and the
// NAT64 prefix — and the `localhost`/`.local` names, but
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

/// Anything that is not a normal public destination. Broader than "private":
/// the point is that a webhook may only be posted to somewhere on the public
/// internet, so every reserved range is refused whether or not it is routable.
function isPrivateIpv4Octets([a, b, c]: number[]): boolean {
  return (
    a === 0 ||                            // "this network"
    a === 10 ||                           // RFC 1918
    a === 127 ||                          // loopback
    (a === 100 && b >= 64 && b <= 127) || // RFC 6598 carrier-grade NAT
    (a === 169 && b === 254) ||           // link-local, incl. cloud metadata
    (a === 172 && b >= 16 && b <= 31) ||  // RFC 1918
    (a === 192 && b === 0 && c === 0) ||  // RFC 6890 protocol assignments
    (a === 192 && b === 168) ||           // RFC 1918
    (a === 198 && b >= 18 && b <= 19) ||  // RFC 2544 benchmarking
    a >= 224                              // multicast, reserved, and broadcast
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

// Guest links name a single activity *instance*, not an activity kind. This is
// the one deliberate difference from ShareResourceKindSchema above: a share for
// kind "progress" exposes every current and future progress activity, which is
// tolerable between two accounts that trust each other and not tolerable for a
// bearer link anyone can hold.
export const GuestResourceKindSchema = z.enum(["card", "activity"]);

export const CreateGuestLinkSchema = z.object({
  resourceKind: GuestResourceKindSchema,
  resourceId: z.string().min(1).max(FieldLimits.externalActivityId),
  ttlSeconds: z.number().int().positive().optional(),
  label: z.string().min(1).max(FieldLimits.title).optional(),
});

export const RegisterGuestActivitySchema = z.object({
  deviceId: z.string().min(1).max(FieldLimits.deviceId),
  // The ActivityKit id on the guest's own device, so a second registration from
  // the same phone replaces the first rather than accumulating dead tokens.
  localActivityId: z.string().min(1).max(FieldLimits.localActivityId),
  // Same hex-validated token type the owner's registration uses: it ends up
  // interpolated into the APNs `/3/device/<token>` path either way.
  pushToken: PushTokenString,
});

/// Ceilings on how long a guest link stays valid.
///
/// A link is a bearer credential printed on a QR code: it gets photographed,
/// screenshotted and left stuck to a fridge, and it cannot be un-published.
/// Expiry, not revocation, is the control that works without anyone
/// remembering to act.
///
/// The activity ceiling is free — a Live Activity is ended by the system after
/// 8 hours and leaves the Lock Screen no more than 4 hours later, so a token
/// outliving 12 hours could only ever unlock content nothing is updating.
export const GuestLinkTtl = {
  activityDefaultSeconds: 12 * 60 * 60,
  activityMaxSeconds: 12 * 60 * 60,
  cardDefaultSeconds: 7 * 24 * 60 * 60,
  cardMaxSeconds: 30 * 24 * 60 * 60,
} as const;

export type DashboardCard = z.infer<typeof DashboardCardSchema>;
export type DashboardCardInput = z.infer<typeof DashboardCardInputSchema>;
export type BatchUpsertCards = z.infer<typeof BatchUpsertCardsSchema>;
export type DashboardItem = z.infer<typeof DashboardItemSchema>;
export type DashboardChart = z.infer<typeof DashboardChartSchema>;
export type ChartStyle = z.infer<typeof ChartStyleSchema>;
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
export type GuestResourceKind = z.infer<typeof GuestResourceKindSchema>;
export type CreateGuestLinkRequest = z.infer<typeof CreateGuestLinkSchema>;
export type RegisterGuestActivity = z.infer<typeof RegisterGuestActivitySchema>;

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
  // Persist the latest WidgetKit APNs result per push token. Off unless the
  // value is exactly "true" because every attempted reload adds one D1 write.
  WIDGET_PUSH_APNS_DIAGNOSTICS?: string;

  // Web sign-in (Sign in with Apple). Any account created in the iOS app can
  // sign in; ADMIN_EMAILS is a separate capability layered on top, not a gate
  // on authenticating at all.
  APPLE_SIGN_IN_CLIENT_ID?: string;       // Services ID, e.g. com.example.zerozerowidget.signin
  APPLE_SIGN_IN_REDIRECT_URI?: string;    // full URL of /auth/apple/callback
  ADMIN_EMAILS?: string;                  // comma-separated addresses holding admin capabilities
  SESSION_SECRET?: string;                // HMAC secret for the admin session cookie
  // Set to "true" to enable the API-token login fallback. It is opt-in so
  // production deployments default to Sign in with Apple only.
  ADMIN_API_TOKEN_LOGIN?: string;

  // Whether a person who has never signed up can become a tenant by signing in
  // on the web. Off unless "true": accounts are created in the iOS app, so
  // someone who merely finds this endpoint gets turned away rather than
  // provisioned. Turning it on makes web sign-in create a tenant the way the
  // app does.
  WEB_SIGNUP_ENABLED?: string;

  // Optional iOS app login. When enabled, the app can exchange a native
  // Sign in with Apple identity token for a tenant API token.
  APPLE_APP_LOGIN_ENABLED?: string;       // set to "true" to enable
  APPLE_APP_SIGN_IN_CLIENT_ID?: string;   // native app bundle id, e.g. com.example.zerozerowidget

  // Master kill switch for the MCP endpoint and the OAuth authorization server
  // that fronts it. Off unless set to "true", so a deployment that has not
  // thought about it exposes neither. Enabling also requires a strong
  // SESSION_SECRET: MCP OAuth signs its client ids and authorization codes with
  // it, and identifies the operator through the admin session cookie.
  MCP_ENABLED?: string;

  // OpenAI plugin submission domain verification. Deployment-specific and
  // served verbatim from /.well-known/openai-apps-challenge when configured.
  OPENAI_APPS_CHALLENGE_TOKEN?: string;

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

  // Where the guest page's "Get 00Widget" button points. Unset means this
  // deployment's own root, which is right when the Worker is all there is;
  // a deployment fronted by a marketing site points it there instead. Must be
  // an http(s) URL — anything else is ignored, since the value is rendered
  // into an href on the page that holds a guest token.
  APP_DOWNLOAD_URL?: string;

  // Optional operator alert when self-service signup creates a new tenant.
  // Both must be present or nothing is sent, so the default deployment needs no
  // Email Routing setup. Worth enabling wherever APPLE_APP_LOGIN_ENABLED is
  // "true", since tenant creation is otherwise silent.
  SIGNUP_ALERTS?: SendEmail;              // [[send_email]] binding in wrangler.toml
  SIGNUP_ALERT_TO?: string;               // recipient; the binding's verified destination
  SIGNUP_ALERT_FROM?: string;             // optional sender on an Email Routing domain

  // App Store subscriptions. Two flags rather than one, because the useful
  // middle state is selling subscriptions without yet enforcing them —
  // grandfathering existing tenants, or letting the verification pipeline run
  // for a while before it is allowed to reject anything.
  //
  // Off unless "true", so a deployment that has not thought about billing keeps
  // behaving exactly as it did before any of this existed. Requiring without
  // enabling fails open: a monetization switch that locks out paying customers
  // on a typo is worse than one that bills nobody.
  SUBSCRIPTIONS_ENABLED?: string;
  SUBSCRIPTION_REQUIRED?: string;
  // Comma-separated product ids sold by this deployment, e.g.
  // com.example.app.pro.monthly,com.example.app.pro.yearly. Empty accepts any
  // product for the right bundle id, which is only sensible in development.
  SUBSCRIPTION_PRODUCT_IDS?: string;
  // "Production" (default) or "Sandbox". Sandbox purchases are free and
  // unlimited, so one must never entitle a production tenant.
  SUBSCRIPTION_ENVIRONMENT?: string;
  // Days past expiry that an entitlement still counts. Covers a late webhook,
  // not a lapsed payment; Apple's own billing grace period arrives in the
  // payload and is honoured separately.
  SUBSCRIPTION_GRACE_DAYS?: string;
}
