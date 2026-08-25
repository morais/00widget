import SwiftUI

/// The reference half of the update-stamp option: what each colour means, what
/// the extension has actually been doing, and why a widget's time is rarely the
/// current time.
///
/// Split out of `DeveloperOptionsView` because it is all reading — three
/// screens' worth of explanation sitting above the one toggle and the one
/// button anybody came to that screen to use.
struct WidgetUpdatesReferenceView: View {
    @State private var timelineEvents = WidgetTimelineDiagnostics.recentEvents

    var body: some View {
        Form {
            Section {
                timelineStartedLegendRow
                ForEach(WidgetUpdateSource.allCases, id: \.self) { source in
                    legendRow(source)
                }
            } header: {
                Text("What the colours mean")
            } footer: {
                Text("The time shown is when the widget last redrew, not when the data changed — a card carries its own updated-at, and a widget can redraw with nothing new to show.")
            }

            if SharedSettings.showWidgetTimestamps {
                Section {
                    if timelineEvents.isEmpty {
                        Text("No timeline executions recorded yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(timelineEvents.prefix(16))) { event in
                            timelineEventRow(event)
                        }
                    }
                    Button("Refresh execution log") {
                        timelineEvents = WidgetTimelineDiagnostics.recentEvents
                    }
                } header: {
                    Text("Recent timeline executions")
                } footer: {
                    Text("Purple records the instant WidgetKit entered the timeline provider, before any network request. Every normal run is followed by a completion in its inferred source colour. A purple start with no matching completion means the extension began running but did not return a timeline.")
                }
            }

            Section {
                ForEach(Self.updateNotes, id: \.title) { note in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(note.title)
                            .font(.subheadline.weight(.semibold))
                        Text(note.body)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Why a widget's time is not the current time")
            } footer: {
                Text("None of this is reported by iOS. The colour is inferred from how early a render arrived relative to the one the widget asked for, so an app-requested reload and a push landing in the same minute are indistinguishable and both read as App — including the very first stamp after switching this on, which this screen itself caused.")
            }
        }
        .navigationTitle("Widget updates")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func legendRow(_ source: WidgetUpdateSource) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(source.tint)
                .frame(width: 10, height: 10)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(source.label)
                    .font(.subheadline.weight(.semibold))
                Text(source.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private var timelineStartedLegendRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(.purple)
                .frame(width: 10, height: 10)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 3) {
                Text("Timeline started")
                    .font(.subheadline.weight(.semibold))
                Text("WidgetKit entered the provider. This is persisted before networking, so it survives an extension termination that prevents a new widget render.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private func timelineEventRow(_ event: WidgetTimelineDiagnostics.Event) -> some View {
        let source = event.source
        let tint: Color = event.phase == .started ? .purple : (source?.tint ?? .secondary)
        let title = event.phase == .started ? "Started" : "Completed · \(source?.label ?? "Unknown")"
        let matchingCompletionExists = event.phase == .started && timelineEvents.contains {
            $0.runId == event.runId && $0.phase == .completed
        }

        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title)
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text(event.date, format: .dateTime.hour().minute().second())
                        .font(.caption.monospacedDigit())
                }
                Text(event.widgetKey)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if event.phase == .started && !matchingCompletionExists {
                    Text("No matching completion")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.purple)
                }
            }
        }
    }

    private struct Note {
        let title: String
        let body: String
    }

    private static let updateNotes: [Note] = [
        Note(
            title: "iOS decides, the app asks",
            body: "A timeline ends with \"refresh after this date\". That is the earliest acceptable time, not a promise. The system delivers reloads opportunistically and will run one late, or not at all, if the device is busy or the budget is spent."
        ),
        Note(
            title: "There is a daily budget, per widget",
            body: "Apple budgets roughly 40–70 reloads a day for a widget someone looks at often, counted per placement rather than per app. Two widgets showing the same card each have their own allowance."
        ),
        Note(
            title: "Pushes come out of the same budget",
            body: "A WidgetKit push does not bypass the allowance — Apple budgets pushes the same way as timeline refreshes. So every blind poll not asked for is one more reload available to a push, which fires because something actually changed."
        ),
        Note(
            title: "The server throttles before Apple does",
            body: "Each push token gets a minimum spacing between pushes plus a refill-over-time burst allowance, so a chatty producer cannot spend a day's reloads in an hour and leave the widget dark all evening."
        ),
        Note(
            title: "The timeline is a backstop, and it adapts",
            body: "While pushes are arriving, a widget asks for a refresh every four hours — enough to notice the push path breaking silently. When they stop, it drops to hourly. It tells the two apart by noticing it was woken well before it asked to be, which is the same signal the colour above reports."
        )
    ]
}
