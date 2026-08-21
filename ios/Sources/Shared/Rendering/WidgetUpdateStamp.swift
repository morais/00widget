import Foundation
import SwiftUI

/// What caused the render a widget is currently showing.
///
/// Nothing in WidgetKit reports this. It is inferred, and the inference is the
/// interesting part: a widget cannot observe its own reloads, so the only
/// evidence available is *when* a run happened relative to when the previous
/// run asked to be woken. See `WidgetRefreshPolicy` for that comparison, and
/// `DeveloperOptionsView` for the version of this explanation a person reads.
public enum WidgetUpdateSource: String, CaseIterable, Codable, Sendable {
    /// Woken well ahead of schedule with no app request nearby: a WidgetKit
    /// push, which the server only sends when a card actually changed.
    case push
    /// The containing app asked for the reload — a foreground sync, a settings
    /// change, a card deleted.
    case app
    /// The widget's own timeline fired at roughly the time it asked for. A
    /// blind poll: it happens whether or not anything changed.
    case scheduled
    /// This render never reached the server. The content is whatever was last
    /// cached, however old that is.
    case offline

    public var label: String {
        switch self {
        case .push: return "Push"
        case .app: return "App"
        case .scheduled: return "Scheduled"
        case .offline: return "Offline"
        }
    }

    public var tint: Color {
        switch self {
        case .push: return .green
        case .app: return .blue
        case .scheduled: return .orange
        case .offline: return .red
        }
    }

    public var explanation: String {
        switch self {
        case .push:
            return "A WidgetKit push woke the widget. The server only sends one when a card actually changed, so this is the update path worth spending the budget on."
        case .app:
            return "The app asked for the reload — usually because you had just brought it to the foreground, changed a setting, or deleted a card."
        case .scheduled:
            return "The widget's own timeline came due and it refreshed blind. It had no way to know whether anything had changed before asking."
        case .offline:
            return "The refresh never reached the server: no credentials, or the request failed. The widget is drawing whatever it had cached, which may be much older than the time shown."
        }
    }

    /// A run this recent after the app asked for a reload is attributed to the
    /// app rather than to a push. Both arrive ahead of schedule and there is no
    /// signal that separates them, so this is a window, not a fact — a push
    /// landing inside it is reported as `app`.
    public static let appReloadAttributionWindow: TimeInterval = 90

    public static func classify(
        wokenEarly: Bool,
        refreshSucceeded: Bool,
        appReloadAt: Date?,
        now: Date = Date()
    ) -> WidgetUpdateSource {
        // Precedence, not a separate axis: a render that fetched nothing is the
        // most important thing to say about it, whatever woke it.
        guard refreshSucceeded else { return .offline }
        guard wokenEarly else { return .scheduled }
        if let appReloadAt {
            let age = now.timeIntervalSince(appReloadAt)
            // A marker ahead of this process's clock is not evidence that the
            // app just asked for a reload. Clock correction, cross-process
            // snapshots, or restored defaults can otherwise make every early
            // push look blue until wall time catches up with the marker.
            if age >= 0, age < appReloadAttributionWindow {
                return .app
            }
        }
        return .push
    }
}

/// When a widget last rendered, and what triggered it.
public struct WidgetUpdateMark: Equatable, Sendable {
    public let date: Date
    public let source: WidgetUpdateSource

    public init(date: Date, source: WidgetUpdateSource) {
        self.date = date
        self.source = source
    }
}

/// The corner badge itself. Deliberately tiny and monospaced: it sits on top of
/// a card's own content, and a proportional clock jitters as the digits change.
public struct WidgetUpdateStampView: View {
    public let mark: WidgetUpdateMark

    public init(mark: WidgetUpdateMark) {
        self.mark = mark
    }

    public var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(mark.source.tint)
                .frame(width: 5, height: 5)
            Text(mark.date, format: .dateTime.hour().minute().second())
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityLabel("Updated \(mark.date.formatted(date: .omitted, time: .standard)), source \(mark.source.label)")
    }
}

public extension View {
    /// Puts the stamp in the top-right corner when the developer option is on
    /// and the caller supplied a mark. Both conditions are checked here so no
    /// call site can render the badge by forgetting the flag.
    ///
    /// The content is inset rather than simply overlaid: a card's own status
    /// glyph sits in that same corner, and a diagnostic badge that hides the
    /// status of the thing it annotates is a poor diagnostic.
    @ViewBuilder
    func widgetUpdateStamp(_ mark: WidgetUpdateMark?) -> some View {
        if let mark, SharedSettings.showWidgetTimestamps {
            padding(.top, 14)
                .overlay(alignment: .topTrailing) {
                    WidgetUpdateStampView(mark: mark)
                }
        } else {
            self
        }
    }
}
