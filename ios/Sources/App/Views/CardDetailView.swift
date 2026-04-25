import SwiftUI

struct CardDetailView: View {
    @EnvironmentObject var env: AppEnvironment
    let card: DashboardCard

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CardView(card: card, context: .app)

                if let actions = card.actions, !actions.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Actions").font(.headline)
                        ForEach(actions) { action in
                            Button {
                                Task {
                                    guard let client = env.apiClient() else { return }
                                    try? await client.runAction(id: action.id, cardId: card.id, source: "app")
                                }
                            } label: {
                                Label(action.label, systemImage: "bolt.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(action.role == .destructive ? .red : .accentColor)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Raw JSON").font(.headline)
                    Text(jsonString)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(8)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Example curl").font(.headline)
                    Text(curlExample)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(8)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                HStack {
                    Button("Refresh") { Task { await env.fetchCards() } }
                    Spacer()
                    Button("Delete from cache", role: .destructive) {
                        var cards = CardCache.load().cards
                        cards.removeAll { $0.id == card.id }
                        try? CardCache.save(cards)
                        env.loadCachedCards()
                    }
                }
            }
            .padding()
        }
        .navigationTitle(card.title)
    }

    private var jsonString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(card), let s = String(data: data, encoding: .utf8) else {
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
