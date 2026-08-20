import Foundation

/// How long a widget waits before asking for another blind reload.
///
/// A widget's daily reload budget is shared between timeline refreshes and
/// WidgetKit pushes. Apple documents roughly 40–70 reloads a day for a widget
/// someone looks at often — "widget reloads every 15 to 60 minutes" — and says
/// pushes are budgeted the same way: "Like timeline updates, the system budgets
/// WidgetKit push notifications and delivers them opportunistically."
///
/// So the two compete, and they are not worth the same. A timeline refresh is
/// blind: it fires whether or not anything changed, and it costs an API call to
/// find out. A push fires *because* something changed. Spending the budget on
/// pushes puts more real changes on screen than spending it on polling.
///
/// The old 15-minute interval asked for ~96 reloads a day on its own, before a
/// single push. Against a 40–70 budget that was never granted — iOS was already
/// dropping most of them, and choosing which to drop without knowing which
/// mattered. Asking for 24 a day is a request that can actually be met, which
/// is why this is not simply "refresh less often": a reload that happens beats
/// one that is requested and denied.
///
/// Deliberately a constant rather than something adaptive. The obvious signal —
/// how long since the last refresh — is set by whatever interval this function
/// last returned, so a policy that reads it oscillates rather than converges.
/// Knowing whether pushes are actually arriving needs a fact the extension does
/// not have; until it does, one honest number is better than a feedback loop
/// that lies.
enum WidgetRefreshPolicy {
    /// The safety net. Pushes carry real changes; this catches a device that
    /// missed one, and refreshes a widget nobody is publishing to.
    static let interval: TimeInterval = 60 * 60

    static func next(from now: Date = Date()) -> Date {
        now.addingTimeInterval(interval)
    }
}
