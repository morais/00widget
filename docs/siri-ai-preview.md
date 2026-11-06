# Siri AI preview prototype

Built for the iOS 27.3 / macOS 27.3 Siri AI Developer Preview. Xcode 27.2
continues to build the app without the new tools or skills. The app still
deploys back to iOS 26.

## Capabilities

The November 4 routing update adds direct parameters for ordinary Live
Activity creation and updates, plus common card updates. Advanced JSON tools
remain available for the full data model. A dedicated Live Activity skill
distinguishes Lock Screen/Dynamic Island requests from dashboard/Home Screen
cards. The tool inventory is now 19.

- Find account-owned cards by title or status and fetch their complete state.
- Read freshness-aware status with a custom Siri snippet.
- Resolve eligible on-screen cards and export a text snapshot to other apps.
- Run published actions by label, with enforced confirmation where required.
- Create summary, progress, list, and chart cards from generable structured
  input. Publish every existing template using complete public-API JSON.
- Replace or delete a selected card with confirmation. Cards with existing
  producer-owned actions cannot be replaced: their read representation omits
  write-only webhook bindings. Create another card or update via the producer.
- Find and inspect owned activities; publish, update, and end them.
- Create read-only guest links for cards and activities after confirmation.

Publishing is remote and uses the publisher credential held in app-only
Keychain storage. Normal device credentials remain read/action credentials;
the server enforces scopes. Manually configured publisher keys still work.
Confirmed actions and guest links use the app-only app credential.

The app skill explains template choice, JSON shapes, data freshness, immutable
activity attributes, and the difference between a display and an underlying
job. Skills guide selection; they do not enforce authorization or confirmation.
Publication receipts report missing devices, pending tokens, and API warnings.

## SDK and distribution

`SiriTools.swift` is gated by `canImport(AppIntents, _version: 301.2)` and its
types by `@available(iOS 27.3, *)`. Observed module versions are 301.1.16 in
Xcode 27.2 and 301.2.7.2 in Xcode 27.3 beta (27C5020n). The skills post-build
step runs only when the selected toolchain contains appintentsskillsprocessor.
It writes Metadata.appintents/Skills.skillsc, the same output as Xcode's native
skills-bundle rule. The older toolchain removes that file to prevent stale
metadata when switching SDKs.

Use `DEVELOPER_DIR` for each build; do not change the machine's default Xcode.
For the preview upload, run the existing upload script with `--ios-only
--internal-only` under Xcode beta. Internal-only export prevents accidental
external TestFlight or App Store distribution. Apple currently enables custom
Siri tools in development builds and internal TestFlight, not external builds.

Activity management requires a server supporting `GET /v1/live-activities
?ownedOnly=true` and its `ownedOnly: true` response marker. It fails closed on
an older deployment. This avoids selecting a shared activity with an external
id that happens to match an activity owned by the current account.

## Device smoke test

On an Apple Intelligence-capable Mac running macOS 27.3 beta in Portugal,
enable Siri AI with matching supported system/Siri languages. Build and run
the iOS app using My Mac (Designed for iPad). Whether the preview indexes its
tools and app skill in this compatibility environment still needs empirical
verification; compiling that destination alone does not prove Siri execution.
The Simulator is not a substitute for this test.

After signing in and opening 00Widget, try:

1. "What needs attention in 00Widget?"
2. Open a real card: "Tell me about this card."
3. "Create a packing list in 00Widget with passport, charger, and tickets."
4. "Create a chart in 00Widget using these readings: 2, 4, 3, 5."
5. "Change that packing list to include headphones." Confirm replacement.
6. "Run [an actual published action label] for [card name] in 00Widget."
   Verify both the safe path and the cancellation/confirmed path.
7. "Track my oven timer for ten minutes on the Lock Screen with 00Widget."
   Check the receipt and the physical iPhone separately; a Mac cannot prove
   Dynamic Island rendering. Then update and explicitly end that activity.
8. "Create a read-only link to my packing list in 00Widget."
9. Delete the test cards and end all test activities.

Verify success in both the server dashboard and devices; do not infer delivery
from an accepted HTTP request. Repeat failed/ambiguous prompts with varied
wording and record results before expanding the prototype's distribution.

## Verification on November 3, 2026

- Xcode 27.2 device build: passed; new Siri tools and compiled skill absent.
- Xcode 27.3 beta device build: passed; 16 tools, generable card input, and
  compiled app skill present in extracted metadata and the exported IPA.
- My Mac (Designed for iPad) build with the beta SDK: passed; same 16 tools.
- All 251 iOS tests passed on an iOS 27.2 simulator under both toolchains,
  including launch of the app built against the newer SDK.
- Backend typecheck and 751 tests passed. Ownership filtering was deployed;
  public health check passed. No database migration was required.
- Internal-only TestFlight build: 1.7 (202611032326). Exported signing gates
  passed, including production app/widget APNs and App Clip associations.
  Apple accepted both iOS and tvOS uploads; processing was pending at handoff.
- Real Siri conversations, custom-skill orchestration, and physical-device
  push display remain to be tested. This Mac was still on macOS 27.2.

## Routing regression reported on November 4

The real Mac prompt "Can you create a live activity tracking my lunch break
using 00widget?" returned "Card published". The server contained a new Siri
summary card called Lunch Break and no matching Live Activity. That confirms
custom tool execution from the iOS app on Mac, but failed surface selection.

The revision gives ordinary activity creation and updates direct parameters
instead of requiring generated JSON, adds a dedicated Live Activity skill,
and makes tool descriptions and receipts distinguish surfaces. Common card
updates also have direct parameters; retained list items preserve their IDs,
values, status, and metadata. Known countdowns stay fresh until their end.
Publication logs record only the route and outcome in the Publishing category.

Revision build: 1.7 (202611041235), internal-only. The Xcode 27.3 beta build
passed, and all 259 iOS tests passed using Xcode 27.2. The exported IPA contains 19 tools and both
compiled skills; Start a Live Activity requires only a title. The 27.2 SDK
build still contains no custom tool metadata or compiled skills. The exported
app retains minimum iOS 26.0. Apple accepted both iOS and tvOS uploads; real Siri routing
must be retried after installing the new build.

Recheck these prompts on macOS 27.3 after installing the revised build. These
are real Siri integration cases, not deterministic unit-test claims:

| Request | Expected tool / server result |
| --- | --- |
| Can you create a live activity tracking my lunch break using 00widget? | Start a Live Activity; new activity titled Lunch Break, no new card; no invented duration |
| Track a 45-minute lunch break on my Lock Screen in 00Widget | Start a Live Activity; endsAt and staleAt agree at roughly now + 45 minutes |
| Create a Home Screen card called Lunch Break with value In progress | Create a Home Screen dashboard card; explicit card request wins even though the subject is a break |
| Set that Live Activity's subtitle to Back soon | Update a Live Activity; same activity instance and countdown, no new card |
| Give that Live Activity another 20 minutes from now | Update a Live Activity; end and freshness advance together |
| Change the Siri Test dashboard card to 84 points | Update a dashboard card; confirmation, same card id, unrelated fields preserved |
| End my lunch-break Live Activity | End a published Live Activity; confirmation; no deletion of similarly named dashboard cards |

Check the server resource type, not only the spoken success message. This
revision doesn't remove the accidentally created Lunch Break card.

Apple references:
- https://developer.apple.com/news/?id=gdk2umrf
- https://developer.apple.com/documentation/appintents/siri-ai-developer-preview
- https://developer.apple.com/documentation/appintents/bringing-custom-actions-and-content-to-siri
- https://developer.apple.com/documentation/appintents/orchestrating-complex-actions-with-app-skills
