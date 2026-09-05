import Foundation
import SwiftUI

public enum DashboardStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case unknown
    case good
    case warning
    case critical
    case running
    case finished
    case paused
    case offline

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DashboardStatus(rawValue: raw) ?? .unknown
    }

    public var tint: Color {
        switch self {
        case .good, .finished: return .green
        case .warning, .paused: return .orange
        case .critical: return .red
        case .running: return .blue
        case .offline, .unknown: return .secondary
        }
    }

    /// Statuses worth surfacing when someone asks what needs looking at.
    ///
    /// `unknown` counts: it is the decoder's fallback for a status this build
    /// predates, so a card wearing it is one the app cannot vouch for.
    /// `paused` is deliberately in both this group and `isActive` — a paused
    /// washer is running and stuck at the same time — which is why these are
    /// three overlapping predicates rather than one partition.
    public var needsAttention: Bool {
        switch self {
        case .warning, .critical, .offline, .paused, .unknown: return true
        case .good, .finished, .running: return false
        }
    }

    public var isActive: Bool {
        self == .running || self == .paused
    }

    public var isHealthy: Bool {
        self == .good || self == .finished
    }

    public var label: String {
        switch self {
        case .unknown: return "Unknown"
        case .good: return "Good"
        case .warning: return "Warning"
        case .critical: return "Critical"
        case .running: return "Running"
        case .finished: return "Finished"
        case .paused: return "Paused"
        case .offline: return "Offline"
        }
    }

    /// A stable, non-colour representation used anywhere status space is
    /// constrained. Producer-supplied `statusIcon` describes a transient
    /// detail; this symbol always communicates the semantic status itself.
    public var symbolName: String {
        switch self {
        case .unknown: return "questionmark.circle.fill"
        case .good: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        case .running: return "play.circle.fill"
        case .finished: return "checkmark.seal.fill"
        case .paused: return "pause.circle.fill"
        case .offline: return "wifi.slash"
        }
    }
}

public extension MetricSignal {
    var tint: Color {
        switch self {
        case .favorable: return .green
        case .neutral: return .secondary
        case .caution: return .orange
        case .unfavorable: return .red
        }
    }

    var symbolName: String {
        switch self {
        case .favorable: return "checkmark.circle.fill"
        case .neutral: return "circle.fill"
        case .caution: return "exclamationmark.triangle.fill"
        case .unfavorable: return "xmark.octagon.fill"
        }
    }
}

public extension LiveActivityKind {
    /// A stable semantic accent for Live Activity surfaces. Charging uses
    /// green rather than inheriting each platform's default blue/white tint.
    var tint: Color {
        switch self {
        case .charging: return .green
        case .appliance, .progress: return .blue
        case .job, .timer: return .orange
        case .generic: return .accentColor
        }
    }

    func tint(for signal: MetricSignal?) -> Color {
        signal?.tint ?? tint
    }
}

/// The one name and the one glyph for the state where a person has to act.
///
/// Both were written out at each site that drew them — five copies of the
/// words and, worse, two different symbols: every iOS surface and the tvOS
/// widget cell used `AttentionBadge`'s person-and-exclamation, while the tvOS
/// status chips drew whatever `statusIcon` the *producer* had sent. That field
/// means "what this activity is doing right now", so a chip could read
/// hammer + "Needs you" — a glyph saying `building` beside words saying a human
/// must intervene, describing different things in one capsule.
public enum AttentionPresentation {
    public static let label = "Needs you"
    public static let symbolName = "person.crop.circle.badge.exclamationmark"
}

public extension LiveActivitySession {
    var tint: Color { kind.tint(for: signal) }
    var semanticStatusIcon: String? { statusIcon ?? signal?.symbolName }

    /// The words for the pill that names the current state, and the glyph that
    /// goes in it. One property each, derived from the same condition, so the
    /// two halves of one badge cannot come to disagree — which is exactly what
    /// they had done.
    var statusChipLabel: String {
        needsUserAttention ? AttentionPresentation.label : state.capitalized
    }

    var statusChipSymbolName: String? {
        needsUserAttention ? AttentionPresentation.symbolName : semanticStatusIcon
    }
    /// A warning row is the activity's explicit hand-off to its operator.
    /// Other warning-like states can mean degraded machinery rather than a
    /// human decision, so they do not silently become "needs you".
    var needsUserAttention: Bool { activeItems.contains(where: \.needsUserAttention) }
}

public extension LiveActivityItem {
    func tint(base: Color = .secondary) -> Color {
        status?.tint ?? ChartSeriesPalette.tint(index: 0, base: base, semantic: semantic)
    }

    var needsUserAttention: Bool { status == .warning }
}

public extension DashboardCard {
    /// A card only promises that the operator can step in when it has both an
    /// attention state and an action to take. A warning without a button is an
    /// observation, not an actionable hand-off.
    var needsUserAttention: Bool {
        status.needsAttention && !(actions?.isEmpty ?? true)
    }

    /// See `LiveActivitySession.statusChipLabel`. A card's fallbacks are its
    /// own: the status's name, and the semantic glyph a producer sent with it.
    var statusChipLabel: String {
        needsUserAttention ? AttentionPresentation.label : status.label
    }

    var statusChipSymbolName: String? {
        needsUserAttention ? AttentionPresentation.symbolName : statusIcon
    }

    /// Whether the typed attribution would only repeat what the subtitle
    /// already says.
    ///
    /// `producer` arrived long after the convention it duplicates. Every
    /// integration guide taught a subtitle shaped `"<Agent> · <context>"`, and
    /// producers kept writing them after gaining somewhere structured to put
    /// the name — so a card commonly carries "Growth Agent" twice, once in
    /// each. On a phone that is redundant; in a tvOS grid cell it costs a
    /// whole line of the few a card has, and the line it costs was being spent
    /// truncating one of the two copies.
    ///
    /// The label has to be the whole of the subtitle's first clause, not
    /// merely its first characters. "Growth" against "Growth Agent · up 18" is
    /// a *different* producer, whose attribution says something the subtitle
    /// does not — dropping it would lose information rather than save a line.
    /// So what follows the label must be the end of the string or the
    /// separator the convention puts there, and a space alone is not enough.
    var producerRepeatsSubtitle: Bool {
        guard let label = producer?.label.trimmingCharacters(in: .whitespaces),
              !label.isEmpty,
              let subtitle
        else { return false }
        guard subtitle.lowercased().hasPrefix(label.lowercased()) else { return false }
        let rest = subtitle.dropFirst(label.count).drop(while: \.isWhitespace)
        guard let next = rest.first else { return true }
        return Self.subtitleSeparators.contains(next)
    }

    /// What producers put between a name and the context after it.
    private static let subtitleSeparators: Set<Character> = ["·", "•", "—", "–", "-", "|", ":", ","]
}

public extension DashboardTemplate {
    /// Whether a card body spends one of its lines on the card's own
    /// `subtitle`.
    ///
    /// `list` does not — its column is rows — so on a surface laid out that
    /// way the header is the only place the producer can appear, and the
    /// attribution is kept whatever the subtitle happens to say. Every other
    /// template draws the subtitle under the headline, which is where the
    /// duplicate `producerRepeatsSubtitle` describes shows up.
    ///
    /// This is the *card body's* question. A detail panel that draws
    /// everything, and the spoken summary, both present the subtitle whatever
    /// the template is, so they ask `producerRepeatsSubtitle` on its own.
    var drawsCardSubtitle: Bool { self != .list }
}
