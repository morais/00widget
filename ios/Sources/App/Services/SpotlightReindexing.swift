// iOS 27's `IndexedEntityQuery`, and the only place in this target that names
// it.
//
// The gate is the same pattern as `Sources/Widgets/FullPageWidgetFamily.swift`
// and exists for the same reason: this repository is built against two SDKs —
// iOS 27 on the development machine, iOS 26 on the machine that archives for
// the App Store — and `IndexedEntityQuery` is absent from the older one
// entirely, so naming it there is a compile-time error no `#available` check
// can rescue.
//
// AppIntents carries its own module version, so the gate asks that rather than
// asking the compiler its own. Observed `-user-module-version`: `300.5.12` in
// the iOS 26.5 SDK, `301.0.51.1.102` in the iOS 27.0 SDK. Gating on the SDK
// rather than on `#if compiler(>=6.4)` matters because only the SDK decides
// whether the symbol resolves; a point release pairing a newer Swift with a
// 26.x SDK would switch a compiler check on and break the submission machine.
//
// Everything the two methods do lives in `SpotlightIndex`, ungated, so it is
// compiled and tested on both machines. What is behind the gate is the
// conformance and two lines of delegation — as little as the feature can be.
#if canImport(AppIntents, _version: 301)

import AppIntents
import CoreSpotlight

/// Lets the system repair the index without waiting for the app to be opened.
///
/// This is the fix for the staleness the donation design otherwise cannot
/// reach. `CardCache.save` is called from both timeline providers, so a
/// push-driven widget refresh moves the cache with the app closed, and only the
/// app donates — by design, or a push would re-index on every reload. Until iOS
/// 27 there was no way for anything to notice the gap; `IndexedEntityQuery` is
/// the system offering to ask.
///
/// The runtime `@available` is not redundant with the gate. The gate says the
/// SDK can name the protocol; this says the OS running the app implements it,
/// and the app still deploys back to iOS 26.
@available(iOS 27.0, *)
extension DashboardCardEntityQuery: IndexedEntityQuery {

    /// `indexDescription` is ignored, and the reason is that this app has
    /// nothing to vary. It carries a protection class, for an app that keeps
    /// several indexes at different ones; every donation here goes to
    /// `CSSearchableIndex.default()`. Re-donating into the default index when
    /// asked about a class we never wrote to costs a write and repairs nothing,
    /// which is the harmless direction to be wrong in.
    public func reindexEntities(
        for identifiers: [DashboardCardEntity.ID],
        indexDescription: CSSearchableIndexDescription
    ) async throws {
        await SpotlightIndex.reindex(ids: Set(identifiers), in: CardCache.load().cards)
    }

    public func reindexAllEntities(
        indexDescription: CSSearchableIndexDescription
    ) async throws {
        await SpotlightIndex.matchIndex(to: CardCache.load().cards)
    }
}

#endif
