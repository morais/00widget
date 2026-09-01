import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var showingWidgetGuide = false
    /// Explicit rather than implicit so a Spotlight result, a shortcut, or a
    /// `zerozerowidget://card/<id>` link can push a card the person never
    /// tapped. The elements are the same destination strings the in-app
    /// NavigationLinks use.
    @State private var path: [String] = []
    @State private var searchText = ""

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Widgets")
                .refreshable { await env.fetchCards() }
                .task { await env.refreshInstalledWidgetCount() }
                .searchable(text: $searchText, prompt: "Search cards")
                .onAppear {
                    applyRequestedCard()
                    applyRequestedSearch()
                }
                .onChange(of: env.requestedCardId) { _, _ in applyRequestedCard() }
                .onChange(of: env.requestedSearchQuery) { _, _ in applyRequestedSearch() }
                .navigationDestination(for: String.self) { id in
                    if let card = card(forDestination: id) {
                        CardDetailView(card: card)
                    } else {
                        // The card went away underneath us — deleted samples, or
                        // a sync that dropped it. Rendering nothing leaves a blank
                        // pushed screen, so pop back to the list instead.
                        DismissingDetailPlaceholder()
                    }
                }
                .sheet(isPresented: $showingWidgetGuide) {
                    NavigationStack {
                        WidgetSetupGuideView()
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") { showingWidgetGuide = false }
                                }
                            }
                    }
                }
        }
    }

    private func guestLinkBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "link")
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                env.guestLinkBanner = nil
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .font(.callout)
        .padding(12)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    /// Pushes the card an intent or link asked for, replacing whatever was on
    /// the stack.
    ///
    /// Deliberately pushes the id even when no matching card is in memory yet:
    /// a cold launch runs this before the first fetch returns, and
    /// `navigationDestination` already handles an id it cannot resolve by
    /// popping back. Dropping the request instead would make the link do
    /// nothing on exactly the launch where it was the reason the app opened.
    private func applyRequestedCard() {
        guard let id = env.requestedCardId else { return }
        path = [destination(for: id)]
        env.requestedCardId = nil
    }

    /// Fills the search field from "Search 00Widget for boiler".
    ///
    /// Pops the stack first: arriving from a search while a card detail is
    /// pushed would run the search behind a screen the person cannot see past,
    /// which reads as the phrase having done nothing.
    private func applyRequestedSearch() {
        guard let query = env.requestedSearchQuery else { return }
        path = []
        searchText = query
        env.requestedSearchQuery = nil
    }

    private func matchesSearch(_ card: DashboardCard) -> Bool {
        CardSearch.matches(card, term: searchText)
    }

    private var visibleCards: [DashboardCard] { env.cards.filter(matchesSearch) }
    private var visibleSharedCards: [DashboardCard] { env.sharedCards.filter(matchesSearch) }
    private var visibleGuestCards: [DashboardCard] { env.guestCards.filter(matchesSearch) }

    /// Cards reaching the app through a share or a guest link are namespaced in
    /// the navigation path, so an incoming id has to be matched against all
    /// three lists to be pushed to the right screen.
    private func destination(for id: String) -> String {
        if env.cards.contains(where: { $0.id == id }) { return id }
        if env.sharedCards.contains(where: { $0.id == id }) { return "shared:\(id)" }
        if env.guestCards.contains(where: { $0.id == id }) { return "guest:\(id)" }
        return id
    }

    private func card(forDestination id: String) -> DashboardCard? {
        if id.hasPrefix("shared:") {
            let cardId = String(id.dropFirst("shared:".count))
            return env.sharedCards.first { $0.id == cardId }
        }
        if id.hasPrefix("guest:") {
            let cardId = String(id.dropFirst("guest:".count))
            return env.guestCards.first { $0.id == cardId }
        }
        return env.cards.first { $0.id == id }
    }

    @ViewBuilder
    private var content: some View {
        // Two scroll views rather than one with a branch inside: removing the
        // last card shrinks the content, and a shared scroll view keeps its old
        // offset, leaving the user parked on blank space below the empty state.
        if visibleCards.isEmpty && visibleSharedCards.isEmpty && visibleGuestCards.isEmpty {
            ScrollView {
                if let banner = env.guestLinkBanner {
                    guestLinkBanner(banner)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                }

                #if ZW_SUBSCRIPTIONS_ENABLED
                // Also here, not only alongside cards. Someone who has never
                // subscribed usually has nothing published yet, so putting the
                // notice only on the populated dashboard hid it from exactly
                // the person it is addressed to.
                SubscriptionNotice()
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                #endif

                // "No widgets yet" is the wrong sentence for a search that
                // matched nothing — the cards are there, the term is not.
                Group {
                    if hasAnyCard {
                        noSearchResults
                    } else {
                        emptyState
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 420)
            }
            .id("empty")
            .background(Color.primary.opacity(0.025))
        } else {
            ScrollView {
                LazyVStack(spacing: 16) {
                    if let banner = env.guestLinkBanner {
                        guestLinkBanner(banner)
                    }

                    #if ZW_SUBSCRIPTIONS_ENABLED
                    // A banner rather than a modal: the cards below are the
                    // last state every widget received, which is exactly what
                    // someone opening the app during a lapse wants to see.
                    SubscriptionNotice()
                    #endif

                    if env.shouldShowWidgetSetupHint {
                        widgetSetupHint
                    }

                    if env.hasSampleCards && !SharedSettings.hideSampleIndicators {
                        sampleNotice
                    }

                    ForEach(visibleCards) { card in
                        NavigationLink(value: card.id) {
                            CardView(card: card, context: .app, density: .compact)
                        }
                        .buttonStyle(.plain)
                    }

                    if !visibleSharedCards.isEmpty {
                        Text("Shared with you")
                            .font(.title3.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 12)

                        ForEach(visibleSharedCards) { card in
                            NavigationLink(value: "shared:\(card.id)") {
                                VStack(alignment: .leading, spacing: 8) {
                                    if let owner = card.sharedBy?.ownerEmail {
                                        Label("From \(owner)", systemImage: "person.fill")
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(.secondary)
                                    }
                                    CardView(card: card, context: .app, density: .compact)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if !visibleGuestCards.isEmpty {
                        Text("Shared links")
                            .font(.title3.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 12)

                        ForEach(visibleGuestCards) { card in
                            NavigationLink(value: "guest:\(card.id)") {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label("Read-only link", systemImage: "link")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.secondary)
                                    CardView(card: card, context: .app, density: .compact)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .id("cards")
            .background(Color.primary.opacity(0.025))
        }
    }


    private var hasAnyCard: Bool {
        !(env.cards.isEmpty && env.sharedCards.isEmpty && env.guestCards.isEmpty)
    }

    private var noSearchResults: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No matching cards")
                .font(.headline)
            Text("Nothing published here matches \u{201C}\(searchText)\u{201D}.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.dashed")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No widgets yet")
                .font(.headline)
            Text("Cards appear here once an agent publishes them. Put one on your Home Screen or Lock Screen to see it without opening the app.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)

            Button("Show me how to add a widget") {
                showingWidgetGuide = true
            }
            .buttonStyle(.borderedProminent)

            Button("Generate sample widgets") {
                env.generateSampleCards()
                // The empty state this replaces is the element focus is on,
                // and it disappears without saying why.
                AccessibilityAnnouncement.post("Sample widgets added to your dashboard.")
            }
            .buttonStyle(.borderedProminent)
            Text("Samples are generated on this device and can be removed at any time.")
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
        }
        .padding()
    }

    private var widgetSetupHint: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Add 00Widget to your Home Screen", systemImage: "square.grid.2x2")
                .font(.subheadline.weight(.semibold))

            Text("You don't have a widget installed yet, so these cards only show up inside the app.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button("Show me how") { showingWidgetGuide = true }
                    .buttonStyle(.borderedProminent)
                Button("Not now") { env.didDismissWidgetSetupHint = true }
                    .buttonStyle(.bordered)
                    .tint(.primary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.accentColor.opacity(0.12))
        )
    }

    private var sampleNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("These are samples", systemImage: "info.circle")
                .font(.subheadline.weight(.semibold))

            Text("Sample widgets are generated on this device to show what 00Widget looks like. No agent published them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Remove sample widgets", role: .destructive) {
                env.clearSampleCards()
                AccessibilityAnnouncement.post("Sample widgets removed.")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
        )
    }
}

private struct DismissingDetailPlaceholder: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Color.clear.onAppear { dismiss() }
    }
}
