// iOS 27's `IndexedEntityQuery` and `SyncableEntity`, and the only place in
// this target that names either.
//
// The gate is the same pattern as `Sources/Widgets/FullPageWidgetFamily.swift`
// and exists for the same reason: this repository is built against two SDKs —
// iOS 27 on the development machine, iOS 26 on the machine that archives for
// the App Store — and both protocols are absent from the older one
// entirely, so naming either there is a compile-time error no `#available`
// check can rescue.
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

/// Cross-device-stable identity so Siri hands conversations across
/// iPhone/Mac/Watch.
///
/// Conformance is nearly free because the precondition already holds: a
/// `DashboardCardEntity`'s id *is* the card's server-provided stable id
/// (`DashboardCardEntity(card).id == card.id`), identical on every device
/// signed into the same tenant — never a device-local UUID. Samples,
/// guest-link and shared cards never reach the entity at all
/// (`SpotlightIndex.indexable`), so nothing syncable names something another
/// device cannot resolve to the same tenant-owned thing. No relevance-API
/// change in 27, so scores stay as they are; there is just more wrist traffic
/// over them with Siri on watchOS 27.
@available(iOS 27.0, *)
extension DashboardCardEntity: SyncableEntity {}

#endif
