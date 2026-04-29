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
        if env.cards.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(env.cards) { card in
                        NavigationLink(value: card.id) {
                            CardView(card: card, context: .app)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .navigationDestination(for: String.self) { id in
                if let c = env.cards.first(where: { $0.id == id }) {
                    CardDetailView(card: c)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.dashed")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No cards yet")
                .font(.headline)
            Text("Publish one from your agent, or tap below to generate local samples.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Button("Generate sample cards") {
                env.generateSampleCards()
            }
            .buttonStyle(.borderedProminent)
            Button("Fetch from backend") {
                Task { await env.fetchCards() }
            }
        }
        .padding()
    }
}
