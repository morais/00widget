import SwiftUI
import UIKit

/// How to attach Claude or ChatGPT to this account through the MCP endpoint.
///
/// A separate screen from Agent config on purpose: that section hands over a
/// token for something the owner runs themselves, and this is the other route
/// entirely — the assistant asks for permission and is issued its own
/// credential, so nothing is pasted anywhere and no secret is on screen.
struct ConnectAgentGuideView: View {
    @EnvironmentObject var env: AppEnvironment
    @Environment(\.openURL) private var openURL
    @State private var copiedEndpoint = false

    var body: some View {
        List {
            Section {
                Text("A connector lets an assistant publish cards and Live Activities on your behalf without you handing it a token. It asks for permission once, you approve it while signed in, and it is issued its own credential.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Said here rather than by hiding the screen: the explanation is
            // worth reading before signing in, but the flow genuinely cannot
            // finish without an account, because the permission screen
            // resolves an existing one and never creates it.
            if env.apiKey.isEmpty {
                Section {
                    Label(
                        "Sign in on the previous screen first. Approving a connector needs an account that already exists — the permission screen cannot create one.",
                        systemImage: "person.crop.circle.badge.exclamationmark"
                    )
                    .font(.subheadline)
                }
            }

            Section {
                Step(1, "Tap Connect Claude below. It opens claude.ai in Safari with the connector details already filled in.")
                Step(2, "Sign in to claude.ai if it asks, then tap Add.")
                Step(3, "Approve the permission screen. It publishes to whichever 00Widget account you are signed in as there.")

                if let url = claudeConnectorURL {
                    Button {
                        openURL(url)
                    } label: {
                        Label("Connect Claude", systemImage: "arrow.up.forward.app")
                    }
                }
            } header: {
                Text("Claude")
            } footer: {
                Text("You only do this once. A connector belongs to your Claude account rather than to a device, so it is there afterwards wherever you use Claude — web, desktop, iPhone, and iPad.")
            }

            Section {
                Text("ChatGPT has no prefilled link, and it takes a custom connector only after developer mode is turned on. Follow OpenAI's instructions, then paste this address when it asks for the MCP server.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Link(
                    destination: URL(string: "https://help.openai.com/en/articles/12584461-developer-mode-and-mcp-apps-in-chatgpt")!
                ) {
                    Label("Developer mode and MCP apps in ChatGPT", systemImage: "arrow.up.forward.app")
                }
                if let endpoint = mcpEndpoint {
                    Text(endpoint)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Button(copiedEndpoint ? "Copied" : "Copy address") {
                        UIPasteboard.general.string = endpoint
                        copiedEndpoint = true
                    }
                }
            } header: {
                Text("ChatGPT")
            }

            Section {
                Text("Agent config on the previous screen is the other way in: a token for something you run yourself, like a script or a terminal agent. A connector does not need it, and an assistant you connect here never sees it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Connect an agent")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The account's own MCP endpoint, derived from the configured server
    /// rather than hardcoded — a self-hosted deployment gets its own address
    /// here, and the connector link has to point at the same one.
    private var mcpEndpoint: String? {
        guard let base = APIClientConfig.validatedBaseURL(from: env.serverBaseURL) else {
            return nil
        }
        return base.appendingPathComponent("mcp").absoluteString
    }

    /// claude.ai opens its add-connector sheet prefilled from these query
    /// items. The path is not one the Claude app claims, so this stays in
    /// Safari, which is where the flow actually works.
    ///
    /// The endpoint is escaped by hand rather than through `URLQueryItem`,
    /// which leaves `:` and `/` bare. Both spellings are legal, but only the
    /// fully escaped one has been confirmed against claude.ai.
    private var claudeConnectorURL: URL? {
        guard
            let endpoint = mcpEndpoint,
            let escaped = endpoint.addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed)
        else { return nil }
        return URL(
            string: "https://claude.ai/customize/connectors"
                + "?modal=add-custom-connector&connectorName=00Widget&connectorUrl=\(escaped)"
        )
    }

    /// RFC 3986 unreserved characters. Everything else in a query value is
    /// escaped, which is what produces the `%3A%2F%2F` form.
    private static let queryValueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
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
