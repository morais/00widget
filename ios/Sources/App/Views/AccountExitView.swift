import SwiftUI

/// Device sign-out, account-level Agent-token rotation, and account deletion.
///
/// Together on one screen because each controls the lifetime of account access,
/// and because it keeps destructive controls off the Settings screen proper,
/// where they would sit among switches people use every day.
///
/// Apple requires an account an app can create to be deletable from that app,
/// and requires deletion rather than deactivation. The consequences are stated
/// before the button, and the button asks once more — which the same guidance
/// permits.
struct AccountExitView: View {
    @EnvironmentObject var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var confirmingSignOut = false
    @State private var confirmingAgentTokenRotation = false
    @State private var confirmingDelete = false

    /// Called after a successful sign-out so Settings can reset what it was
    /// showing — the copied-config acknowledgement refers to a token that no
    /// longer exists.
    var onSignOut: () -> Void = {}
    /// Called after rotation so Settings stops treating the superseded token as
    /// one the user has already copied.
    var onAgentTokenRotated: () -> Void = {}

    var body: some View {
        List {
            Section {
                Button(env.signOutInProgress ? "Signing out…" : "Sign out", role: .destructive) {
                    confirmingSignOut = true
                }
                .disabled(env.signOutInProgress)
                // On the button, not on the List: a confirmation dialog becomes
                // a popover on iPad, and a popover anchors to whatever view the
                // modifier is attached to.
                .confirmationDialog(
                    "Sign out?",
                    isPresented: $confirmingSignOut,
                    titleVisibility: .visible
                ) {
                    Button("Sign out", role: .destructive) {
                        Task {
                            if await env.signOut() {
                                onSignOut()
                                dismiss()
                            }
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This signs out only this device. Your agents, connectors, shared links, and account remain active.")
                }
            } header: {
                blockHeader("Sign out")
            } footer: {
                Text("Signs this device out and leaves your account and everything in it untouched. You can sign back in at any time.")
            }

            Section {
                Text("Use this if a token copied from Agent config may have been exposed. Every old Agent-config token stops working and one replacement is created.")
                    .font(.subheadline)

                Button(role: .destructive) {
                    confirmingAgentTokenRotation = true
                } label: {
                    if env.agentTokenRotationInProgress {
                        Label("Rotating…", systemImage: "hourglass")
                    } else {
                        Label("Rotate agent token", systemImage: "key.fill")
                    }
                }
                .disabled(env.agentTokenRotationInProgress)
                .confirmationDialog(
                    "Rotate the agent token?",
                    isPresented: $confirmingAgentTokenRotation,
                    titleVisibility: .visible
                ) {
                    Button("Rotate agent token", role: .destructive) {
                        Task {
                            if await env.rotateAgentToken() {
                                onAgentTokenRotated()
                                dismiss()
                            }
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("All existing Agent-config tokens will be revoked. Agents using them stop publishing until you give them the replacement shown in Settings. Approved connectors stay connected.")
                }
            } header: {
                blockHeader("Agent access")
            } footer: {
                Text("This does not sign out your devices, delete any data, revoke shared links, or disconnect approved connectors.")
            }

            // One section, not four. Split across several, the list of what
            // goes read as one item among many — as though it were a summary
            // of some of it rather than all of it.
            Section {
                Text("Deleting your account erases it from the server, with everything in it. Not part of it: all of it, immediately, with no grace period and no way to undo it.")
                    .font(.subheadline)

                Text("That means:")
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 2)

                Bullet("Every card, and its history.")
                Bullet("Every Live Activity, running or finished.")
                Bullet("Every agent token and every connector you approved, so agents stop publishing at once.")
                Bullet("Every widget registration, which leaves placed widgets empty.")
                Bullet("Every link you shared, and every invitation addressed to you.")
                Bullet("Your email address, and the account itself.")

                Text("Nothing of the account is kept, and nothing is archived.")
                    .font(.subheadline)
                    .padding(.top, 2)

                #if ZW_SUBSCRIPTIONS_ENABLED
                Text("One thing this cannot do is cancel an App Store subscription. Only the App Store can, and it has to be done separately.")
                    .font(.subheadline)
                    .padding(.top, 2)
                Button {
                    if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
                        openURL(url)
                    }
                } label: {
                    Label("Manage subscriptions", systemImage: "arrow.up.forward.app")
                }
                #endif
            } header: {
                blockHeader("Delete account")
            }

            Section {
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    if env.accountDeletionInProgress {
                        Label("Deleting…", systemImage: "hourglass")
                    } else {
                        Label("Delete account", systemImage: "trash")
                    }
                }
                .disabled(env.accountDeletionInProgress)
                .confirmationDialog(
                    "Delete your account?",
                    isPresented: $confirmingDelete,
                    titleVisibility: .visible
                ) {
                    Button("Delete account", role: .destructive) {
                        Task {
                            if await env.deleteAccount() {
                                onSignOut()
                                dismiss()
                            }
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This permanently deletes your account and everything in it. It cannot be undone.")
                }

            } footer: {
                Text("You can sign in again afterwards, but it starts a new, empty account.")
            }

            if let error = env.appleLoginError {
                Section {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension AccountExitView {
    /// Section headers on this screen do more work than usual: they are the
    /// only thing separating a routine act from an irreversible one, so they
    /// are titles rather than the small grey captions a Form header defaults
    /// to.
    fileprivate func blockHeader(_ title: String) -> some View {
        Text(title)
            .font(.title3.weight(.bold))
            .foregroundStyle(.primary)
            .textCase(nil)
            .padding(.top, 12)
            .padding(.bottom, 2)
    }
}

private struct Bullet: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "minus")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 1)
    }
}
