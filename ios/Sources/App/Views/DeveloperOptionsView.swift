import SwiftUI

/// Reached by tapping the version number in Settings.
///
/// Distinct from `DeveloperView`, which is the debug console gated behind the
/// `ZW_DEBUG_TOOLS` build setting and compiled out of every shipping build.
/// These are options a curious owner can turn on in a released app, so both
/// default to off and both explain what they do.
struct DeveloperOptionsView: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var showRawCardDetails = SharedSettings.showRawCardDetails
    @State private var showWidgetTimestamps = SharedSettings.showWidgetTimestamps

    var body: some View {
        Form {
            Section {
                Toggle("Show raw JSON and curl", isOn: $showRawCardDetails)
                    .onChange(of: showRawCardDetails) { _, value in
                        SharedSettings.setShowRawCardDetails(value)
                    }
            } header: {
                Text("Card details")
            } footer: {
                Text("Adds the card's wire format and an equivalent curl command to each card's detail screen — the exact request an agent would send to publish it.")
            }

            Section {
                Toggle("Show update timestamp", isOn: $showWidgetTimestamps)
                    .onChange(of: showWidgetTimestamps) { _, value in
                        SharedSettings.setShowWidgetTimestamps(value)
                        env.reloadWidgetTimelines()
                    }
            } header: {
                Text("Home Screen widgets")
            } footer: {
                Text("Draws the time of the last render in the top-right corner of every Home Screen widget, tinted by what triggered it. Lock Screen widgets are left alone: they are a few points tall and monochrome, so a badge there would push out the content it annotates.")
            }

            Section {
                ForEach(WidgetUpdateSource.allCases, id: \.self) { source in
                    legendRow(source)
                }
            } header: {
                Text("What the colours mean")
            } footer: {
                Text("The time shown is when the widget last redrew, not when the data changed — a card carries its own updated-at, and a widget can redraw with nothing new to show.")
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
        .navigationTitle("Developer")
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
