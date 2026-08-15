import SwiftUI

/// The links this account has handed out, with a way to take them back.
///
/// Deliberately not behind ZW_SHARING_ENABLED. That flag governs the
/// email-based, account-to-account sharing feature; guest links are a separate
/// one that a build can offer while sharing is stripped. Minting lives in the
/// ungated card and activity detail views, so revoking has to be reachable
/// under the same conditions — otherwise a build could hand out links it has no
/// way to withdraw.
struct SharedGuestLinksView: View {
    @EnvironmentObject var env: AppEnvironment

    @State private var links: [APIClient.GuestLinkSummary] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var revoking: Set<String> = []

    var body: some View {
        List {
            if let error {
                Section {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }

            Section {
                if links.isEmpty && !isLoading {
                    Text("You haven't shared any links.")
                        .foregroundStyle(.secondary)
                }
                ForEach(links) { link in
                    row(for: link)
                }
            } footer: {
                Text("Anyone holding one of these can see that one card or Live Activity, and nothing else. They cannot run actions. Revoking takes effect immediately.")
            }
        }
        .navigationTitle("Links you've shared")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isLoading && links.isEmpty { ProgressView() }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func row(for link: APIClient.GuestLinkSummary) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(link.label ?? link.resourceId ?? "Shared link")
                    .lineLimit(1)
                Text(subtitle(for: link))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if revoking.contains(link.id) {
                ProgressView()
            } else {
                Button("Revoke", role: .destructive) {
                    Task { await revoke(link) }
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func subtitle(for link: APIClient.GuestLinkSummary) -> String {
        var parts: [String] = []
        if let kind = link.resourceKind {
            parts.append(kind == "activity" ? "Live Activity" : "Card")
        }
        if let expiresAt = link.expiresAt {
            parts.append("until \(expiresAt.formatted(date: .abbreviated, time: .shortened))")
        }
        // A link nobody has opened is worth distinguishing from one in use:
        // it is the cheapest one to take back.
        parts.append(link.lastUsedAt == nil ? "never opened" : "opened")
        return parts.joined(separator: " · ")
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            links = try await env.fetchSharedGuestLinks()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func revoke(_ link: APIClient.GuestLinkSummary) async {
        revoking.insert(link.id)
        defer { revoking.remove(link.id) }
        do {
            try await env.revokeSharedGuestLink(id: link.id)
            links.removeAll { $0.id == link.id }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
