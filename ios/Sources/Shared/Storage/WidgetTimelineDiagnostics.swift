import Foundation

/// Persistent evidence of timeline-provider execution.
///
/// `os.Logger` is useful while a device is attached, but these diagnostics are
/// intended for TestFlight failures that may be inspected much later. Keeping
/// a bounded history in the App Group lets the containing app show a provider
/// start even when the extension was terminated before it could return a new
/// timeline (and therefore before the Home Screen could draw anything new).
public enum WidgetTimelineDiagnostics {
    public enum Phase: String, Codable, Sendable {
        case started
        case completed
    }

    public struct Event: Codable, Identifiable, Sendable {
        public let id: UUID
        public let runId: UUID
        public let widgetKey: String
        public let phase: Phase
        public let date: Date
        public let source: WidgetUpdateSource?
        public let refreshSucceeded: Bool?
    }

    private static let maximumEventCount = 40

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: ZeroZeroWidgetConstants.appGroupIdentifier)
    }

    @discardableResult
    public static func recordStart(widgetKey: String, at date: Date = Date()) -> UUID {
        let runId = UUID()
        append(Event(
            id: UUID(),
            runId: runId,
            widgetKey: widgetKey,
            phase: .started,
            date: date,
            source: nil,
            refreshSucceeded: nil
        ))
        return runId
    }

    public static func recordCompletion(
        runId: UUID,
        widgetKey: String,
        source: WidgetUpdateSource,
        refreshSucceeded: Bool,
        at date: Date = Date()
    ) {
        append(Event(
            id: UUID(),
            runId: runId,
            widgetKey: widgetKey,
            phase: .completed,
            date: date,
            source: source,
            refreshSucceeded: refreshSucceeded
        ))
    }

    public static var recentEvents: [Event] {
        guard
            let data = defaults?.data(forKey: ZeroZeroWidgetConstants.UserDefaultsKeys.widgetTimelineDiagnostics),
            let events = try? JSONDecoder().decode([Event].self, from: data)
        else {
            return []
        }
        return events.sorted { $0.date > $1.date }
    }

    private static func append(_ event: Event) {
        var events = recentEvents.sorted { $0.date < $1.date }
        events.append(event)
        if events.count > maximumEventCount {
            events.removeFirst(events.count - maximumEventCount)
        }
        guard let data = try? JSONEncoder().encode(events) else { return }
        defaults?.set(data, forKey: ZeroZeroWidgetConstants.UserDefaultsKeys.widgetTimelineDiagnostics)
    }
}
