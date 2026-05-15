import SwiftUI

struct TVDashboardView: View {
    @EnvironmentObject var env: TVEnvironment
    @State private var showingSettings = false

    private let cardWidth: CGFloat = 360
    private let cardHeight: CGFloat = 280
    private let cardScale: CGFloat = 1.6

    var body: some View {
        ZStack(alignment: .topTrailing) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button {
                showingSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .padding(20)
            }
            .padding(24)
        }
        .fullScreenCover(isPresented: $showingSettings) {
            TVSettingsView()
                .environmentObject(env)
        }
    }

    @ViewBuilder
    private var content: some View {
        if env.cards.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: cardWidth + 40), spacing: 40)],
                    spacing: 40
                ) {
                    ForEach(env.cards) { card in
                        Button {
                            // No-op: cards are focus targets; pressing select can trigger a future detail view.
                        } label: {
                            scaledCard(card)
                        }
                        .buttonStyle(.card)
                    }
                }
                .padding(60)
            }
        }
    }

    private func scaledCard(_ card: DashboardCard) -> some View {
        CardView(card: card, context: .app)
            .frame(width: cardWidth / cardScale, height: cardHeight / cardScale, alignment: .topLeading)
            .scaleEffect(cardScale, anchor: .topLeading)
            .frame(width: cardWidth, height: cardHeight, alignment: .topLeading)
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            Image(systemName: "square.dashed")
                .font(.system(size: 96))
                .foregroundStyle(.secondary)
            Text("No widgets yet")
                .font(.title)
            Text("Publish one from your agent.")
                .font(.title3)
                .foregroundStyle(.secondary)
            if env.isRefreshing {
                ProgressView()
            }
            if let error = env.lastSyncError {
                Text(error)
                    .font(.body)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 800)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
