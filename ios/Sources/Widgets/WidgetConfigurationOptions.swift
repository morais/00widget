import AppIntents

public enum WidgetCardDensity: String, AppEnum {
    case automatic
    case compact
    case detailed

    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Display density")
    }

    public static var caseDisplayRepresentations: [WidgetCardDensity: DisplayRepresentation] = [
        .automatic: DisplayRepresentation(title: "Automatic"),
        .compact: DisplayRepresentation(title: "Compact"),
        .detailed: DisplayRepresentation(title: "Detailed")
    ]

    var renderDensity: CardRenderDensity {
        switch self {
        case .automatic: return .automatic
        case .compact: return .compact
        case .detailed: return .detailed
        }
    }
}

public enum WidgetStatusFilter: String, AppEnum {
    case all
    case needsAttention
    case active
    case healthy

    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Status filter")
    }

    public static var caseDisplayRepresentations: [WidgetStatusFilter: DisplayRepresentation] = [
        .all: DisplayRepresentation(title: "All cards"),
        .needsAttention: DisplayRepresentation(title: "Needs attention"),
        .active: DisplayRepresentation(title: "Active"),
        .healthy: DisplayRepresentation(title: "Healthy")
    ]

    var fallbackLabel: String {
        switch self {
        case .all: return "all cards"
        case .needsAttention: return "cards needing attention"
        case .active: return "active cards"
        case .healthy: return "healthy cards"
        }
    }

    func includes(_ status: DashboardStatus) -> Bool {
        switch self {
        case .all:
            return true
        case .needsAttention:
            return status == .warning || status == .critical || status == .offline || status == .paused || status == .unknown
        case .active:
            return status == .running || status == .paused
        case .healthy:
            return status == .good || status == .finished
        }
    }
}
