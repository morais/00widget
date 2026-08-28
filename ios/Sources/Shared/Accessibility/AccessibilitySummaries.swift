import Foundation

/// Concise, shared wording for every surface that presents a card as one
/// accessibility element. Siri's status report delegates here too, so spoken
/// card meaning cannot drift between shortcuts, the dashboard, and widgets.
enum CardAccessibilitySummary {
    static func summary(for card: DashboardCard, now: Date = Date()) -> String {
        var sentences: [String] = []

        let headline = [card.value, card.unit]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        if headline.isEmpty {
            sentences.append("\(card.title) is \(card.status.label.lowercased()).")
        } else {
            sentences.append("\(card.title) is \(headline).")
            if card.status != .unknown {
                sentences.append("Status: \(card.status.label.lowercased()).")
            }
        }

        if let progress = card.progress {
            let percent = Int((min(max(progress, 0), 1) * 100).rounded())
            sentences.append("\(percent)% complete.")
        }

        if let subtitle = trimmed(card.subtitle) {
            sentences.append(sentence(subtitle))
        }

        if let deadline = card.deadline {
            sentences.append("Due \(relative(deadline, from: now)).")
        }

        if card.isStale {
            sentences.append("This may be out of date — last updated \(relative(card.updatedAt, from: now)).")
        }

        return sentences.joined(separator: " ")
    }

    private static func trimmed(_ text: String?) -> String? {
        guard let value = text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func sentence(_ text: String) -> String {
        text.hasSuffix(".") || text.hasSuffix("!") || text.hasSuffix("?") ? text : text + "."
    }

    private static func relative(_ date: Date, from now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .numeric
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

enum LiveActivityAccessibilitySummary {
    static func summary(for session: LiveActivitySession) -> String {
        summary(
            title: session.title,
            state: session.state,
            value: session.value,
            unit: session.unit,
            progress: session.progress,
            subtitle: session.subtitle,
            activeItemCount: (session.items ?? []).filter(\.isActive).count,
            isStale: session.isStale
        )
    }

    static func summary(
        title: String,
        state: String,
        value: String?,
        unit: String?,
        progress: Double?,
        subtitle: String?,
        activeItemCount: Int,
        isStale: Bool
    ) -> String {
        var parts = [title]
        let headline = [value, unit]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        parts.append(headline.isEmpty ? state : headline)

        if activeItemCount > 0 {
            parts.append("\(activeItemCount) active")
        }
        if let progress {
            parts.append("\(Int((min(max(progress, 0), 1) * 100).rounded()))% complete")
        }
        if let subtitle = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines), !subtitle.isEmpty {
            parts.append(subtitle)
        }
        if isStale {
            parts.append("may be out of date")
        }
        return parts.joined(separator: ", ")
    }

    static func summary(for item: LiveActivityItem) -> String {
        var parts = [item.title]
        let headline = [item.value, item.unit]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !headline.isEmpty {
            parts.append(headline)
        } else if let status = item.status {
            parts.append(status.label)
        }
        if let progress = item.progress {
            parts.append("\(Int((min(max(progress, 0), 1) * 100).rounded()))% complete")
        }
        if let subtitle = item.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines), !subtitle.isEmpty {
            parts.append(subtitle)
        }
        return parts.joined(separator: ", ")
    }
}
