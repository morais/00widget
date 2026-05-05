import SwiftUI

struct CardDetailView: View {
    @EnvironmentObject var env: AppEnvironment
    let card: DashboardCard
    @State private var pendingAction: ActionDefinition?
    @State private var showRawJson = false
    @State private var showCurlExample = false
    #if ZW_SHARING_ENABLED
    @State private var showShareSheet = false
    #endif

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

                HStack {
                    Spacer()
                    Button("Delete from cache", role: .destructive) {
                        var cards = CardCache.load().cards
                        cards.removeAll { $0.id == currentCard.id }
                        try? CardCache.save(cards)
                        env.loadCachedCards()
                    }
                }
            }
            .padding()
        }
        .refreshable {
            await env.fetchCards()
        }
        .navigationTitle(currentCard.title)
        #if ZW_SHARING_ENABLED
        .toolbar {
            // Only the owner can share; receivers (cards with sharedBy set)
            // cannot re-share.
            if currentCard.sharedBy == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showShareSheet = true
                    } label: {
                        Label("Share", systemImage: "person.crop.circle.badge.plus")
                    }
                }
            }
        }
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
            guard let client = env.apiClient() else { return }
            try? await client.runAction(id: action.id, cardId: resolvedCard.id, source: "app")
        }
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
