import WidgetKit

/// iOS 27's full-page Home Screen widget, `systemExtraLargePortrait`.
///
/// Every reference to that family in this target goes through here, because
/// naming it is a compile-time decision rather than a runtime one and the
/// repository is built against two SDKs: iOS 27 on the development machine,
/// iOS 26 on the machine that archives for the App Store.
///
/// The case is declared in *both* SDKs, so the usual `#available` guard is no
/// help — the iOS 26 SDK marks it `@available(iOS, unavailable)`, which makes
/// merely writing `.systemExtraLargePortrait` a hard error there:
///
///     error: 'systemExtraLargePortrait' is unavailable in iOS
///
/// The gate asks the SDK's WidgetKit its version rather than asking the
/// compiler its own (`#if compiler(>=6.4)` distinguishes today's two Xcodes
/// just as well). Only the SDK decides whether the symbol is available, and a
/// point release that paired Swift 6.4 with a 26.x SDK would switch a compiler
/// check on and break the submission machine — the one failure this indirection
/// exists to prevent. Observed `-user-module-version` for WidgetKit: 664.5.28.100
/// in the iOS 26.5 SDK, 749.0.1 in the iOS 27.0 SDK.
enum FullPageWidgetFamily {

    /// `base` plus the full-page portrait family, when both the SDK being
    /// compiled against and the OS running the extension know it.
    ///
    /// The `#available` check still matters under the iOS 27 SDK: the app
    /// deploys back to iOS 26, where offering the family would be a lie.
    static func adding(to base: [WidgetFamily]) -> [WidgetFamily] {
        #if canImport(WidgetKit, _version: 749)
        if #available(iOS 27.0, *) {
            return base + [.systemExtraLargePortrait]
        }
        #endif
        return base
    }

    /// Whether `family` is the full-page portrait one. False on any SDK or OS
    /// that has no such family, which is the correct answer there.
    static func contains(_ family: WidgetFamily) -> Bool {
        #if canImport(WidgetKit, _version: 749)
        if #available(iOS 27.0, *) {
            return family == .systemExtraLargePortrait
        }
        #endif
        return false
    }
}
