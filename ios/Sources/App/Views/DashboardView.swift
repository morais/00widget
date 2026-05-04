import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var env: AppEnvironment

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Widgets")
                .refreshable { await env.fetchCards() }
        }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            if env.cards.isEmpty && env.sharedCards.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, minHeight: 420)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(env.cards) { card in
                        NavigationLink(value: card.id) {
                            CardView(card: card, context: .app)
                        }
                        .buttonStyle(.plain)
                    }

                    if !env.sharedCards.isEmpty {
                        Text("Shared with you")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)

                        ForEach(env.sharedCards) { card in
                            NavigationLink(value: "shared:\(card.id)") {
                                VStack(alignment: .leading, spacing: 6) {
                                    if let owner = card.sharedBy?.ownerEmail {
                                        Text("From \(owner)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    CardView(card: card, context: .app)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding()
            }
        }
        .navigationDestination(for: String.self) { id in
            if id.hasPrefix("shared:") {
                let cardId = String(id.dropFirst("shared:".count))
                if let c = env.sharedCards.first(where: { $0.id == cardId }) {
                    CardDetailView(card: c)
                }
            } else if let c = env.cards.first(where: { $0.id == id }) {
                CardDetailView(card: c)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.dashed")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No widgets yet")
                .font(.headline)
            Text("Publish one from your agent, or tap below to generate local samples.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Button("Generate sample widgets") {
                env.generateSampleCards()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}
