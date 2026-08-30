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

public extension LiveActivitySession {
    var tint: Color { kind.tint(for: signal) }
    var semanticStatusIcon: String? { statusIcon ?? signal?.symbolName }
}
