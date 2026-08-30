import Foundation

/// One self-contained detail in an agent-authored briefing. Sections are
/// ordered most important first so smaller surfaces can show a prefix without
/// truncating a paragraph halfway through or asking the producer to maintain
/// several summaries that can contradict each other.
public struct DashboardBriefingSection: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var label: String?
    public var text: String

    public init(id: String, label: String? = nil, text: String) {
        self.id = id
        self.label = label
        self.text = text
    }
}

public struct DashboardBriefing: Codable, Hashable, Sendable {
    public var sections: [DashboardBriefingSection]

    public init(sections: [DashboardBriefingSection]) {
        self.sections = sections
    }
}
