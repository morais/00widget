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
}
