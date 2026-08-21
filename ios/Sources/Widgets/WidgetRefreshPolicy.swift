import Foundation

/// How long a widget waits before asking for another blind reload.
///
/// A widget's daily reload budget is shared between timeline refreshes and
/// WidgetKit pushes. Apple documents roughly 40–70 reloads a day for a widget
/// someone looks at often, and says pushes are budgeted the same way: "Like
/// timeline updates, the system budgets WidgetKit push notifications and
/// delivers them opportunistically."
///
/// So the two compete, and they are not worth the same. A timeline refresh is
/// blind: it fires whether or not anything changed, and costs an API call to
/// find out. A push fires *because* something changed. Every blind reload not
/// asked for is budget left for one that carries news.
///
/// The trick is knowing whether pushes are actually arriving, because the
/// timeline is only a backstop while they are. The signal is not "how long
/// since the last run" — that is set by whatever interval this policy last
/// returned, so reading it converges on nothing. It is **how long since the
/// last run compared with what we asked for**. A run that arrives well before
/// its scheduled time was triggered by something else: a push, or the app
/// coming to the foreground. Either means this widget is being kept current by
/// something other than polling.
///
/// That comparison settles in both directions. While pushes arrive, every run
/// is early and the interval stays long. When they stop, the next run happens
/// on schedule, is not early, and the interval drops — and stays down, because
/// each subsequent run is also on schedule. When they resume, the first push
/// makes a run early again.
///
/// Nothing here can force a reload; `.after` is a request against a budget the
/// system owns. Asking for less is how a request gets granted.
enum WidgetRefreshPolicy {
    /// Pushes are landing. The timeline exists to catch the push path breaking
    /// silently — a revoked notification permission, a dead token, an outage —
    /// not to fetch news, so it can be rare.
    static let relaxed: TimeInterval = 4 * 60 * 60

    /// Nothing else is waking this widget, so the timeline is all it has.
    static let unaided: TimeInterval = 60 * 60

    /// A run this far ahead of schedule was triggered by something other than
    /// the timeline. Below 1.0 because the system delivers reloads
    /// "opportunistically" and a scheduled one can land slightly early; well
    /// above 0 so a genuine push is unambiguous.
    static let earlyFraction = 0.85

    /// - Parameter widget: distinguishes one widget's history from another's.
    ///   It has to: with a single shared record, a second widget's run would
    ///   reset the timestamp and make every other widget look woken-early
    ///   forever. Two widgets showing the same thing may share a key — they are
    ///   pushed together anyway.
    static func next(for widget: String, now: Date = Date()) -> Date {
        decide(for: widget, now: now).next
    }

    /// The same step as `next(for:)`, also reporting the comparison it made.
    ///
    /// `wokenEarly` is the one piece of evidence a widget has about why it is
    /// running: it did not ask to be woken this soon, so something else woke
    /// it. The update stamp turns that into a colour; the interval choice
    /// turns it into a cadence. Both read the same fact, so they are computed
    /// once — the record is rewritten here, and a second read would see the
    /// value this call just stored.
    static func decide(for widget: String, now: Date = Date()) -> Decision {
        let previous = record(for: widget)
        let interval = chooseInterval(previous: previous, now: now)
        store(Record(ranAt: now, requested: interval), for: widget)
        return Decision(next: now.addingTimeInterval(interval), wokenEarly: wasEarly(previous: previous, now: now))
    }

    static func wasEarly(previous: Record?, now: Date) -> Bool {
        guard let previous else { return false }
        return now.timeIntervalSince(previous.ranAt) < previous.requested * earlyFraction
    }

    struct Decision {
        var next: Date
        var wokenEarly: Bool
    }

    static func chooseInterval(previous: Record?, now: Date) -> TimeInterval {
        // Nothing learned yet. Start attentive rather than assume the push path
        // works: a widget that never refreshes is worse than one that polls.
        guard previous != nil else { return unaided }
        return wasEarly(previous: previous, now: now) ? relaxed : unaided
    }

    struct Record {
        var ranAt: Date
        var requested: TimeInterval
    }

    // MARK: - Storage

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: ZeroZeroWidgetConstants.appGroupIdentifier)
    }

    private static func key(_ widget: String) -> String {
        "\(ZeroZeroWidgetConstants.UserDefaultsKeys.widgetRefreshRecordPrefix)\(widget)"
    }

    private static func record(for widget: String) -> Record? {
        guard let stored = (defaults ?? .standard).array(forKey: key(widget)) as? [Double],
              stored.count == 2, stored[1] > 0
        else { return nil }
        return Record(ranAt: Date(timeIntervalSince1970: stored[0]), requested: stored[1])
    }

    private static func store(_ record: Record, for widget: String) {
        (defaults ?? .standard).set(
            [record.ranAt.timeIntervalSince1970, record.requested],
            forKey: key(widget)
        )
    }
}
