import SwiftUI

struct TVSettingsView: View {
    @EnvironmentObject var env: TVEnvironment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.opacity(0.95).ignoresSafeArea()

            VStack(spacing: 32) {
                Text("Settings")
                    .font(.system(size: 56, weight: .bold))

                VStack(alignment: .leading, spacing: 18) {
                    row("Signed in as", value: env.appleLoginEmail ?? "—")
                    row("Server", value: env.serverBaseURL)
                    row("Version", value: appVersionString)
                    if let last = env.lastSyncAt {
                        row("Last sync", value: last.formatted(.relative(presentation: .named)))
                    }
                    if let error = env.lastSyncError {
                        row("Last error", value: error, valueColor: .red)
                    }
                }
                .frame(maxWidth: 900, alignment: .leading)
                .padding(36)
                .background(RoundedRectangle(cornerRadius: 24).fill(Color.white.opacity(0.08)))

                HStack(spacing: 24) {
                    Button(role: .destructive) {
                        env.signOut()
                        dismiss()
                    } label: {
                        Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                            .padding(.horizontal, 32)
                            .padding(.vertical, 16)
                    }

                    Button {
                        dismiss()
                    } label: {
                        Text("Done")
                            .padding(.horizontal, 48)
                            .padding(.vertical, 16)
                    }
                }
            }
            .padding(60)
        }
    }

    @ViewBuilder
    private func row(_ key: String, value: String, valueColor: Color = .primary) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 240, alignment: .leading)
            Text(value)
                .font(.title3)
                .foregroundStyle(valueColor)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer()
        }
    }

    private var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(marketing) (\(build))"
    }
}
