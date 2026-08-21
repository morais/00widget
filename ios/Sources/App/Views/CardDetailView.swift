import SwiftUI

struct CardDetailView: View {
    @EnvironmentObject var env: AppEnvironment
    let card: DashboardCard
    @State private var pendingAction: ActionDefinition?
    @State private var actionError: String?
    @State private var showRawJson = false
    @State private var showCurlExample = false
    @State private var showGuestLinkSheet = false
    @State private var confirmingDelete = false
    @State private var deleting = false
    @State private var deleteError: String?
    @Environment(\.dismiss) private var dismiss
    #if ZW_SHARING_ENABLED
    @State private var showShareSheet = false
    #endif

    private var isGuestCard: Bool {
        card.isFromGuestLink || env.guestCards.contains { $0.id == card.id }
    }

    /// Only a card this account owns. A card arriving through a share or a
    /// guest link lives in somebody else's tenant, so there is nothing here
    /// that could delete it — a local-only "delete" would just have it
    /// reappear on the next refresh.
    private var canDelete: Bool {
        !isGuestCard && card.sharedBy == nil
    }

    var body: some View {
        let currentCard = resolvedCard
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CardView(card: currentCard, context: .app) { action in
                    if action.confirm || action.role == .destructive {
                        pendingAction = action
                    } else {
                        run(action)
                    }
                }

                if let actionError {
                    Text(actionError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let deepLink = currentCard.deepLink {
                    deepLinkDestination(deepLink)
                }

                DisclosureGroup("Raw JSON", isExpanded: $showRawJson) {
                    Text(jsonString)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .font(.headline)

                DisclosureGroup("Example curl", isExpanded: $showCurlExample) {
                    Text(curlExample)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .font(.headline)

                if canDelete {
                    if let deleteError {
                        Text(deleteError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack {
                        Spacer()
                        Button(deleting ? "Deleting\u{2026}" : "Delete", role: .destructive) {
                            confirmingDelete = true
                        }
                        .disabled(deleting)
                    }
                }
            }
            .padding()
        }
        .refreshable {
            await env.fetchCards()
        }
        .navigationTitle(currentCard.title)
        .toolbar {
            // Only the owner can share. A card arriving through a share
            // (sharedBy set) or a guest link is not this account's to hand on.
            if currentCard.sharedBy == nil && !isGuestCard {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showGuestLinkSheet = true
                        } label: {
                            Label("Share this card as a link", systemImage: "qrcode")
                        }
                        #if ZW_SHARING_ENABLED
                        Button {
                            showShareSheet = true
                        } label: {
                            Label("Share this card with an account…", systemImage: "person.crop.circle.badge.plus")
                        }
                        #endif
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .sheet(isPresented: $showGuestLinkSheet) {
            GuestLinkShareSheet(
                resourceKind: "card",
                resourceId: currentCard.id,
                title: currentCard.title
            )
            .environmentObject(env)
        }
        #if ZW_SHARING_ENABLED
        .sheet(isPresented: $showShareSheet) {
            ShareCardSheet(card: currentCard)
                .environmentObject(env)
        }
        #endif
        .confirmationDialog(
            "Run action?",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            presenting: pendingAction
        ) { action in
            Button(action.label, role: action.role == .destructive ? .destructive : nil) {
                run(action)
                pendingAction = nil
            }
        } message: { action in
            Text("Run \(action.label) for \(currentCard.title)?")
        }
        .confirmationDialog(
            "Delete \(currentCard.title)?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { delete(currentCard) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteConfirmationMessage(for: currentCard))
        }
    }

    private func deleteConfirmationMessage(for card: DashboardCard) -> String {
        card.isSample
            ? "This sample only exists on this device. Removing it affects nothing else."
            : "This removes the card from the server as well as from this device. Any widget showing it goes blank until an agent publishes it again."
    }

    private func delete(_ card: DashboardCard) {
        Task {
            deleting = true
            deleteError = nil
            defer { deleting = false }
            do {
                try await env.deleteCard(card)
                dismiss()
            } catch {
                deleteError = error.localizedDescription
            }
        }
    }

    private var resolvedCard: DashboardCard {
        if let sharedBy = card.sharedBy,
           let shared = env.sharedCards.first(where: { candidate in
               candidate.id == card.id && candidate.sharedBy?.shareId == sharedBy.shareId
           }) {
            return shared
        }
        return env.cards.first(where: { $0.id == card.id }) ?? card
    }

    private func run(_ action: ActionDefinition) {
        Task {
            actionError = nil
            do {
                if action.confirm || action.role == .destructive {
                    guard let client = env.confirmedActionClient() else {
                        // Returning quietly here made a tapped destructive
                        // action look like it ran.
                        actionError = AppEnvironment.reauthorizationMessage
                        return
                    }
                    try await client.runConfirmedAction(id: action.id, cardId: resolvedCard.id)
                } else {
                    guard let client = env.apiClient() else {
                        actionError = "Server URL or API key not configured."
                        return
                    }
                    try await client.runAction(id: action.id, cardId: resolvedCard.id)
                }
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func deepLinkDestination(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Destination")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(deepLinkDisplay(url))
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func deepLinkDisplay(_ url: URL) -> String {
        guard
            let scheme = url.scheme?.lowercased(),
            (scheme == "http" || scheme == "https"),
            let host = url.host
        else {
            return url.absoluteString
        }
        return "\(scheme)://\(host)"
    }

    private var jsonString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(resolvedCard), let s = String(data: data, encoding: .utf8) else {
            return "—"
        }
        return s
    }

    private var curlExample: String {
        """
        curl -X POST "$BASE_URL/v1/cards/upsert" \\
          -H "Authorization: Bearer $API_KEY" \\
          -H "Content-Type: application/json" \\
          -d '\(jsonString.replacingOccurrences(of: "'", with: "'\\''"))'
        """
    }
}
