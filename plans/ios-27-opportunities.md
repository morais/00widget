# iOS / tvOS 27 opportunities for 00Widget

Deepdive written 2026-09-07, tracked via a 00Widget Live Activity
(start → 3 updates with `staleAt` → end `finished/favorable`, all pushes 200).
Target reader: the machine with the **Xcode 27 / iOS 27 SDK** (this plan was
researched from the iOS 26 submission machine; SDK-verification steps below
need the 27 SDK).

Deployment targets today: iOS 26.0 / tvOS 26.0 (`ios/project.yml.sample`).
Two SDKs build this repo (27 dev, 26 archive) — every 27-only symbol goes
behind the compile-time SDK gate, never a bare `#available`. The established
pattern (see `ios/Sources/Widgets/FullPageWidgetFamily.swift:23-48`):

```swift
#if canImport(WidgetKit, _version: 749)
if #available(iOS 27.0, *) {
    // 27-only reference
}
#endif
```

Gate on the SDK module version, not `#if compiler(...)`. Observed versions:
WidgetKit `664.5.28.100` (26.5) / `749.0.1` (27.0); AppIntents `300.5.12` /
`301.0.51.1.102`. Prove a new gate toggles with a temporary `#error` under
both Xcodes.

## Already done — no action, do not regress

1. **Full-page widget.** `FullPageWidgetFamily.swift` gates
   `systemExtraLargePortrait` correctly. Apple docs confirm it is real
   (iOS/iPadOS/macOS 27+, visionOS 26; Home Screen / Today View / macOS
   Desktop) and the *only* new WidgetKit family in 27 (2 new APIs,
   0 deprecations). Keep the gate until the archive machine moves to Xcode 27.
2. **Spotlight repair.** `Sources/App/Services/SpotlightReindexing.swift`
   adopts `IndexedEntityQuery` behind
   `#if canImport(AppIntents, _version: 301)`. Confirmed in Apple docs
   (iOS 27+). More valuable in 27 than when written: Spotlight was rebuilt
   (semantic + lexical index) and an Island swipe-down "Search or Ask"
   gesture makes it reachable inside any app.
3. **tvOS Dynamic Type.** `Sources/TV/TVLargeText.swift` (`TVTextScale`,
   deliberately ungated — 27 adds a *setting*, not a symbol). Still needs a
   pass on a real tvOS 27 device; Xcode 26 simulators cannot drive the
   setting (use `--large-text-preview` + `TVLargeTextTests` until then).

## Work items, ranked

### 1. Adopt `isDynamicIslandLimitedInWidth` in compact/minimal Island views
- **Why:** WWDC26 sess. 223: in iOS 27 landscape, compact/minimal Island
  views cannot grow in width. New SwiftUI env value
  (`SwiftUI/EnvironmentValues/isDynamicIslandLimitedInWidth`) tells you when.
  This is the system signal for exactly the squeeze/clip problem the
  `compactValueToken` budget in `LiveActivityMinimalPresentation.swift`
  works around heuristically.
- **Where:** `ios/Sources/Widgets/LiveActivityWidget.swift`
  (`MinimalIslandView`, compact leading/trailing), derivations in
  `LiveActivityMinimalPresentation.swift`.
- **How:** when constrained, fall back to the ring instead of the number
  (same fallback ladder, now driven by signal instead of guess). Fits the
  existing gate pattern; needs the 27 SDK to compile.
- **Verify:** probe capture `marketing/screenshots/capture-ios.sh --only island`
  (37s) for portrait; landscape width behavior needs a device (the probe
  answers "what does this look like", never "does it fit" — see AGENTS.md).

### 2. Fix the search-schema comment, verify against the 27 SDK
- **Why:** `Sources/App/Intents/SearchCardsIntent.swift:7-9` claims "iOS 27
  deprecates the protocol in favour of `.system.searchInApp`". Checked
  2026-09-07: `ShowInAppSearchResultsIntent` carries **no** deprecation in
  current Apple docs — but the `.system.search` *schema* is marked
  **Deprecated** on the system-search domain page, and a [forum
  report](https://developer.apple.com/forums/thread/832189) says the 27 SDK
  rejects non-`criteria` params on the intent. The comment is imprecise in a
  load-bearing way.
- **How (27-SDK machine):** grep the AppIntents `.swiftinterface` for
  `searchInApp` vs `search`; rewrite the comment to say what is actually
  deprecated (schema, not protocol); do the schema swap if confirmed. ~30 min.

### 3. `CancellableIntent` for `RunDashboardActionIntent`
- **Why:** exists in the 27 SDK (App Intents add-on behaviors, next to Beta
  `LongRunningIntent`). Agent runs are cancellable by nature; nothing in
  `Sources/` adopts it (only AGENTS.md names the gate shape).
- **Where:** `ios/Sources/Shared/Intents/RunDashboardActionIntent.swift`,
  same `canImport(AppIntents, _version: 301)` gate as `SpotlightReindexing`.
- **Constraint:** keep the `isSafeFromWidget` rule (destructive/confirm →
  deep-link, never run from a widget/island) — user signoff required to
  loosen, per AGENTS.md.

### 4. `LiveActivityIntent` quick actions (spike)
- **Why:** WWDC26 sess. 223: Live Activity buttons can run App Intents
  conforming to `LiveActivityIntent` (e.g. rate an order from the banner).
  Cards already carry `actions` against server webhooks; the spike is one-tap
  *safe* actions (acknowledge, snooze) from Lock Screen / expanded island.
- **Constraints:** extend the `isSafeFromWidget` rule to island buttons;
  buttons do not act in CarPlay. Possible small server question (scope or
  attribution for island-originated runs).

### 5. Liquid Glass audit (no API, two chores)
- **Why:** 27 refines Liquid Glass (diffusion, toolbar layering, icon
  refraction, user transparency slider; tilt-shimmer removed).
- **How:** rebuild the icon in Xcode 27, check light/dark/tinted + small
  sizes (Spotlight, Library, notifications); audit widget/card contrast incl.
  the accented-rendering path (`WidgetAccentedRenderingMode`, referenced from
  the `WidgetFamily.systemExtraLarge` docs). User slider settings change
  effective contrast in the wild.

### 6. App Intents Testing framework + View Annotations API
- **Why:** both new in 27 (WWDC sess. 240/295/343-344). Testing validates
  Siri/Shortcuts/Spotlight through real system pathways without UI
  automation — directly relevant given the "Simulator doesn't rehydrate
  AppIntents" pain documented in AGENTS.md. View Annotations map on-screen
  views to entities for on-screen awareness ("this card").
- **Where:** annotate `CardView`/dashboard rows; add intent tests alongside
  `ZeroZeroWidgetTests`. Medium effort, real discoverability payoff now that
  Siri routes exclusively through App Intents (SiriKit deprecated WWDC26;
  this repo is already App Intents-only — confirmation, not work).

### 7. `SyncableEntity` (evaluate, probably adopt)
- **Why:** cross-device-stable identity so Siri hands conversations across
  iPhone/Mac/Watch. Card ids and `externalActivityId`s are already stable
  strings — *if* they identify the same thing on every device, conformance
  is nearly free. watchOS 27 adds Siri AI + a Siri app on-watch and a
  single-tap Smart Stack gesture: more wrist traffic over the unchanged
  `relevanceScore` lever (no relevance-API change in 27 — no migration,
  just more reason to keep scores honest).

## Evaluated, no action

- New widget/Lock Screen families beyond `systemExtraLargePortrait`: none.
- Live Activity APNs payload shapes: unchanged (`server/src/apns.ts`
  date-stamp still valid). No push-to-start / frequency model change.
- tvOS Top Shelf / focus engine: no 27 API changes found (static Top Shelf
  images still fine; dashboard stays hand-built non-lazy).
- `canOpenURL` deprecation: single weak source — verify in SDK before acting.
- Control Center controls, Foundation Models on-device agents: real but
  optional. `LongRunningIntent` (Beta) is worth knowing for multi-minute
  agent runs (progress → automatic Live Activity), not for normal actions.

## Verification per item

| Item | Check |
| ---- | ----- |
| 1, 3, 4 | Build under both Xcodes (`#error` toggle test for any new gate); `cd server && npx tsc --noEmit && npm test` untouched; island probe capture for item 1 |
| 2 | 27-SDK `.swiftinterface` grep; comment rewrite only |
| 5 | Rebuild icon in Xcode 27 beta; eyeball widget/card contrast, accented mode |
| 6, 7 | New tests in `ZeroZeroWidgetTests` scheme; Siri phrases on device (never Simulator) |
| tvOS carryover | `TVLargeTextTests` + real tvOS 27 device pass |

## Sources (checked 2026-09-07)

- `WidgetFamily.systemExtraLargePortrait` —
  https://developer.apple.com/documentation/widgetkit/widgetfamily/systemextralargeportrait
- `IndexedEntityQuery` —
  https://developer.apple.com/documentation/appintents/indexedentityquery
- `isDynamicIslandLimitedInWidth` —
  https://developer.apple.com/documentation/swiftui/environmentvalues/isdynamicislandlimitedinwidth ;
  WWDC26 sess. 223 summary — https://wwdc.ai/2026/223
- `ShowInAppSearchResultsIntent` (no deprecation banner) —
  https://developer.apple.com/documentation/appintents/showinappsearchresultsintent ;
  system search domain (`search` Deprecated) —
  https://developer.apple.com/documentation/appintents/app-schema-domain-system-and-in-app-search
- SiriKit deprecation / App Intents as only Siri path —
  https://www.apple.com/newsroom/2026/06/apple-aids-app-development-with-new-intelligence-frameworks-and-advanced-tools/
- iOS 27 Island gesture / Spotlight reachability (secondary) —
  Beebom 2026-06-19; Spaceport Live Activities on iOS 27 —
  https://spaceport.build/blog/live-activities-dynamic-island-swiftui
- tvOS 27 scope (secondary) — https://www.geeky-gadgets.com/tvos-27-hands-on-review/
