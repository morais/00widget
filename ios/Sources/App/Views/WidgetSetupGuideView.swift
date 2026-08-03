import SwiftUI

/// Step-by-step instructions for placing a widget. Reachable permanently from
/// Settings, and surfaced automatically on the dashboard until the user has at
/// least one widget installed.
struct WidgetSetupGuideView: View {
    var body: some View {
        List {
            Section {
                Text("00Widget shows the cards your agents publish. The app is where you check and configure them — the point is the widget on your Home Screen, Lock Screen, or in the Dynamic Island.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section("Home Screen") {
                Step(1, "Touch and hold an empty part of the Home Screen until the icons jiggle.")
                Step(2, "Tap Edit in the top-left corner, then tap Add Widget.")
                Step(3, "Search for 00Widget, pick a size, and tap Add Widget.")
                Step(4, "Touch and hold the widget you placed and tap Edit Widget to choose which card it shows.")
            }

            Section("Lock Screen") {
                Step(1, "Touch and hold the Lock Screen, then tap Customize.")
                Step(2, "Choose Lock Screen and tap the area below the clock.")
                Step(3, "Pick 00Widget, then tap the widget to choose a card.")
            }

            Section("Live Activities") {
                Text("Nothing to set up. When an agent starts a Live Activity it appears on the Lock Screen and in the Dynamic Island on its own, for as long as it runs.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("A widget only shows cards this app has already downloaded, so keep notifications enabled — that is how updates reach the widget between refreshes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Add a widget")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct Step: View {
    let number: Int
    let text: String

    init(_ number: Int, _ text: String) {
        self.number = number
        self.text = text
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor))

            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}
