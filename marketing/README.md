# Marketing production guide

This directory owns the repeatable production contract for 00Widget's App
Store and website media. Product positioning, campaign copy, and growth
experiments live in the
[marketing plan](https://github.com/morais/00widget-www/blob/main/plans/00widget-app-store-positioning-report.md);
this repository owns the fixtures, captures, renders, validation, and listing
sync that turn that plan into evidence.

## Sources of truth

Keep each decision in one durable place:

| Concern | Source of truth |
| --- | --- |
| Positioning, sequence rationale, and campaign copy | `00widget-www/plans/00widget-app-store-positioning-report.md` |
| Demo cards and Live Activity state | `ios/Sources/Shared/SampleDataFactory.swift`, pinned by `ios/Tests/SampleDataFactoryTests.swift` |
| Screenshot surfaces and capture behavior | [`screenshots/README.md`](screenshots/README.md) and the capture scripts beside it |
| Promotional copy and composition | `screenshots/generate-promotional.py` |
| Storefront screenshot order | `ios/scripts/upload-appstore-screenshots.py` |
| App Preview story and timing | [`app-preview/README.md`](app-preview/README.md) and `app-preview/ios-main.yaml` |
| App Store text metadata | `ios/appstore-metadata.json` |
| Current unfinished work | [marketing execution status](https://github.com/morais/00widget-www/blob/main/plans/00widget-marketing-execution-status.md) |

Do not copy completed implementation history into the execution tracker. A
durable rendering or capture rule belongs beside the relevant code; a fixture
contract belongs in source and tests; commit history belongs in Git.

## Campaign story

The canonical launch story is one agent-assisted release moving from progress
to a human decision and completion. The seven-card deck supplies the wider
control-room context: Launch, Production, Trials, Support, AI spend, Agent
runs, and Open PRs. Typed producer attribution identifies the responsible
agent without spending compact subtitle space on its name.

Each surface has a distinct job:

- Home Screen widgets establish ambient breadth across several agents.
- The Lock Screen combines persistent Trials and Agent runs accessories with
  the changing Launch Live Activity.
- The dedicated expanded Dynamic Island frame proves the roomier live view on
  hardware that supports it.
- The app proves detail, trends, the pending decision, and safe confirmation.
- The share/App Clip pair proves a read-only guest can see the same card
  without creating an account.
- Apple TV proves the same launch dashboard works as a shared control room.

The App Preview uses a deliberately Launch-free static Home Screen: AI spend,
Production, Trials, and Open PRs stay stable while the Dynamic Island alone
moves Launch from 3/5 to 4/5 to 5/5. This prevents a budgeted WidgetKit refresh
from contradicting the Live Activity or crossfading an otherwise unchanged
hero.

Exact strings belong in `SampleDataFactory`, not in this guide. If a string is
changed for legibility, update both the regular marketing deck and App Preview
fixtures in the same change, then update their tests.

The Launch action uses publisher-supplied confirmation copy rather than the
generic fallback: **Approve launch?** followed by **Publish the announcement
and start the 10% rollout.** Keep that consequence consistent in the regular
fixture, App Preview fixture, approval still, and movie.

## Release asset workflow

Treat a fixture, renderer, capture, or promotional-copy change as an asset
revision across every destination:

1. Run the relevant layout and fixture tests before capture. Small-widget,
   Lock Screen, Dynamic Island, and tvOS fit are separate constraints.
2. Run `marketing/screenshots/capture-all.sh` for fresh raw and promotional
   sets across both iPhones, iPad, and Apple TV.
3. Perform the human visual review in
   [`screenshots/README.md`](screenshots/README.md). Manifest success is not
   creative approval.
4. Run `marketing/app-preview/run.sh ios-main`, validate the MP4, and review
   its causal sequence at full resolution.
5. Dry-run, apply, and verify `ios/scripts/sync-appstore-listing.sh`.
6. In the sibling `00widget-www` repository, run `npm run build:assets` and
   `npm run check:assets` so website derivatives come from the newly accepted
   captures and preview.
7. Upload the App Preview and select its poster manually in App Store Connect;
   the listing sync does not manage either one.
8. Inspect the resulting storefront and public website rather than inferring
   customer-visible state from a successful API response.

### Manual App Store completion gate

`sync-appstore-listing.sh` manages text metadata, the App Clip experience, and
screenshots. App Store Preview upload and poster selection are deliberately
manual. For every campaign revision that changes fixtures, captures, preview
timing, or preview copy, the release is not complete until all three boxes are
closed:

- [ ] Upload the current `artifacts/app-preview/preview.mp4` to the intended
  App Store version.
- [ ] Select the populated opening hero at `output.posterTime` in
  `marketing/app-preview/ios-main.yaml` as the poster.
- [ ] Inspect the processed movie and poster on the App Store product-page
  preview, then record completion in the campaign execution status.

The listing sync prints a pointer to this gate on every dry-run, apply, and
verification run. Do not mark a campaign revision distributed based only on
the automated listing verification.

Generated captures and movies under `artifacts/` are gitignored. App Store
upload and website derivatives distribute them; neither makes the raw capture
tree a versioned source asset. Preserve an accepted local set until every
destination has been verified.
