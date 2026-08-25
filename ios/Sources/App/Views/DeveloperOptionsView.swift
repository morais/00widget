import SwiftUI

/// Reached by tapping the version number in Settings.
///
/// Distinct from `DeveloperView`, which is the debug console gated behind the
/// `ZW_DEBUG_TOOLS` build setting and compiled out of every shipping build.
/// These are options a curious owner can turn on in a released app, so all
/// three default to off and all three explain what they do.
///
/// Kept to the switches themselves: the colour legend, the notes on why a
/// widget's time is not the current time, and the push registration rows are
/// drilldowns, because they are reference and diagnostics rather than things to
/// change.
struct DeveloperOptionsView: View {
    @EnvironmentObject var env: AppEnvironment
    // The same storage `RawPayloadDisclosure` gates on, so the toggle and the
    // screens it governs cannot disagree.
    @AppStorage(
        ZeroZeroWidgetConstants.UserDefaultsKeys.showRawPayloads,
        store: UserDefaults(suiteName: ZeroZeroWidgetConstants.appGroupIdentifier)
    )
    private var showRawPayloads = false
    @AppStorage(
        ZeroZeroWidgetConstants.UserDefaultsKeys.showDummyAccountData,
        store: UserDefaults(suiteName: ZeroZeroWidgetConstants.appGroupIdentifier)
    )
    private var showDummyAccountData = false
    @State private var showWidgetTimestamps = SharedSettings.showWidgetTimestamps

    var body: some View {
        Form {
            Section {
                Toggle("Show raw JSON and curl", isOn: $showRawPayloads)
            } header: {
                Text("Payloads")
            } footer: {
                Text("Adds the stored wire format and an equivalent curl command to the detail screen of every card and Live Activity — the exact request an agent would send to publish it.")
            }

            Section {
                Toggle("Show dummy account data", isOn: $showDummyAccountData)
            } header: {
                Text("Account")
            } footer: {
                Text("Shows \(DummyAccountData.email) and a visibly fake token on the Settings screen instead of your own, for a screenshot or a shared screen. Nothing else changes: the real token still authorizes every request. Copy agent config copies what is on screen, so turn this off before handing the token to an agent.")
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
                NavigationLink("How widget updates work") {
                    WidgetUpdatesReferenceView()
                }
                NavigationLink("Widget push registration") {
                    WidgetPushRegistrationView().environmentObject(env)
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("The first explains what each stamp colour means and why a widget's time is rarely the current time. The second shows the push token this device gave the server, and can send it again.")
            }
        }
        .navigationTitle("Developer")
        .navigationBarTitleDisplayMode(.inline)
    }
}
