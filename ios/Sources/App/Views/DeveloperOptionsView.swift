import SwiftUI

/// Reached by tapping the version number in Settings.
///
/// Every switch here is one a curious owner can turn on in a released app, so
/// each defaults to off and each explains what it does. There is no build-gated
/// tier behind this screen any more: what used to be one held a debug console
/// whose every control duplicated something the app does on its own.
///
/// Kept to the switches themselves: the colour legend, the notes on why a
/// widget's time is not the current time, the push registration rows and the
/// app's own state are drilldowns, because they are reference and diagnostics
/// rather than things to change.
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
    @State private var hideSampleIndicators = SharedSettings.hideSampleIndicators
    @State private var reviewAccessCode = ""

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
                NavigationLink("App state") {
                    AppStateView().environmentObject(env)
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("The first explains what each stamp colour means and why a widget's time is rarely the current time. The second shows the push token this device gave the server, and can send it again. The third is what this install currently is — worth reading before describing a symptom.")
            }

            // Last, and together, because these two are about how the app
            // looks to someone else — a screenshot, a recording, a shared
            // screen — rather than about what it does. Neither changes any
            // behaviour, which is exactly why each one says so below.
            Section {
                Toggle("Show dummy account data", isOn: $showDummyAccountData)
                Toggle("Hide sample indicators", isOn: $hideSampleIndicators)
                    .onChange(of: hideSampleIndicators) { _, value in
                        SharedSettings.setHideSampleIndicators(value)
                        // The badges are drawn by the widget extension too,
                        // which is a separate process reading the same App
                        // Group flag and will not notice on its own.
                        env.reloadWidgetTimelines()
                    }
            } header: {
                Text("Screenshots and recordings")
            } footer: {
                Text("""
                Dummy account data shows \(DummyAccountData.email) and a visibly fake token on the Settings screen instead of your own. The real token still authorizes every request, and Copy agent config copies what is on screen — so turn this off before handing the token to an agent.

                Hiding sample indicators drops the SAMPLE badges and the "these are samples" notice from generated cards, in the app and on the Home Screen. They are still samples; only the labelling goes.
                """)
            }

            if env.apiKey.isEmpty && env.reviewLoginAvailable {
                Section {
                    SecureField("Review access code", text: $reviewAccessCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button(env.reviewLoginInProgress ? "Signing in…" : "Sign in to review account") {
                        Task {
                            if await env.signInWithReviewAccessCode(reviewAccessCode) {
                                reviewAccessCode = ""
                            }
                        }
                    }
                    .disabled(
                        env.reviewLoginInProgress
                            || reviewAccessCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )

                    if let error = env.appleLoginError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("App review")
                } footer: {
                    Text("Available only on servers with a preconfigured review tenant. The access code is exchanged for this device's normal app credentials and is not stored.")
                }
            }
        }
        .navigationTitle("Developer")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if env.apiKey.isEmpty {
                await env.refreshReviewLoginAvailability()
            }
        }
    }
}
