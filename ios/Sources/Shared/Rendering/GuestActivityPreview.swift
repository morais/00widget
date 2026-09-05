import SwiftUI

/// What a guest sees once the App Clip has started the Live Activity they were
/// sent — the only place this product draws a running activity in an ordinary
/// app context rather than on a system surface.
///
/// The activity itself is on the Lock Screen, where this person may not look
/// for a while, so the clip has to prove that something happened. It draws the
/// same content the Lock Screen does — identity, what the run is doing, its
/// headline and progress, and the first few item rows — from the same
/// `ContentState` the activity was started with, so the two cannot disagree
/// about what was shared.
///
/// It is deliberately not the Lock Screen renderer itself: `LockScreenView`
/// reads `\.activityFamily`, an environment value that only means anything
/// inside a Live Activity, and it lives in the widget extension. What is
/// shared instead is the part that carries a rule — `budgetedPresentationItems`
/// decides which rows appear, the same way every other surface does, so the
/// clip cannot quietly show active work the rest of the product hides.
///
/// It lives in `Sources/Shared` although only the Clip draws it, for the reason
/// `CardGridCell` does: a renderer that only an app extension or a clip can
/// reach is one no unit test can measure, and the last two layout defects to
/// reach TestFlight were both in views nothing cheap could see. This one is the
/// first thing a stranger sees of the product, which is a poor place to find
/// that out late.
public struct GuestActivityPreview: View {
    let session: LiveActivitySession

    public init(session: LiveActivitySession) {
        self.session = session
    }

    private var tint: Color { session.tint }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            headline
            if let progress = session.progress {
                ProgressRow(progress: progress, label: nil)
            }
            let rows = session.budgetedPresentationItems(fillingTo: 3)
            if !rows.isEmpty {
                VStack(spacing: 8) {
                    ForEach(rows) { item in
                        row(item)
                    }
                }
            }
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// The chip sits beside the title where there is room for both and drops
    /// below it where there is not.
    ///
    /// This is arithmetic rather than a matter of taste: the pill is
    /// `fixedSize` and about 110 points wide, which on the narrowest iPhone
    /// leaves the title under 100 — so "App launch" wrapped to two lines
    /// beside a pill with room to spare, and layout priority cannot conjure
    /// width that is not there. `ViewThatFits` picks the first arrangement
    /// whose ideal size fits, which is the honest way to ask the question.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                identity
                Spacer(minLength: 8)
                chip
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) { identity }
                chip
            }
        }
    }

    private var identity: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: session.icon ?? "circle.fill")
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.headline)
                if let subtitle = session.subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// What the run is *doing*, in the words and the glyph the rest of the
    /// product uses for it. Both come from `statusChip*`, which derives them
    /// from one condition — the pair had already drifted into a glyph saying
    /// one thing beside words saying another.
    private var chip: some View {
        HStack(spacing: 4) {
            if let symbol = session.statusChipSymbolName {
                Image(systemName: symbol)
            }
            Text(session.statusChipLabel)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.14), in: Capsule())
        .fixedSize()
    }

    @ViewBuilder
    private var headline: some View {
        if let value = session.value {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.largeTitle.weight(.semibold))
                    .fontDesign(.rounded)
                if let unit = session.unit {
                    Text(unit)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func row(_ item: LiveActivityItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon ?? "circle.fill")
                .font(.caption)
                .foregroundStyle((item.status ?? .unknown).tint)
                .frame(width: 16)
            // Both halves of a row shrink a little before either truncates.
            // A row is a name and its reading; losing the end of one to an
            // ellipsis loses the fact, and on the narrowest phone both were
            // going at once ("Announce…" against "Needs appr…").
            Text(item.title)
                .font(.subheadline)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 8)
            if let value = ValueUnit.joined(item.value, item.unit) {
                Text(value)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
    }
}
