import WidgetKit
import SwiftUI
import ActivityKit

struct ZeroZeroWidgetLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ZeroZeroWidgetActivityAttributes.self) { context in
            LockScreenView(attributes: context.attributes, state: context.state, systemIsStale: context.isStale)
                .activityBackgroundTint(LiveActivityBackground.tint(for: context.attributes.kind, signal: context.state.signal))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(tapURL(for: context.attributes))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    // No `layoutPriority`. The three top-row regions compete
                    // for one width, and priority here spends it on identity —
                    // which is the wrong half. `MinimalIslandView` states the
                    // rule for the circle and it holds just as well here: the
                    // app icon is already on screen, so a title that wins room
                    // from the number wins it from the only thing the operator
                    // is looking at.
                    Label(context.attributes.title, systemImage: iconName(attributes: context.attributes, state: context.state))
                        .font(.caption)
                        .foregroundStyle(context.attributes.kind.tint(for: context.state.signal))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.leading, 8)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Group {
                        if context.state.showsItemCount {
                            Text("\(context.state.activeItems.count) active")
                                .font(.headline)
                        } else if let endsAt = context.state.endsAt {
                            LiveActivityCountdownText(
                                endsAt: endsAt,
                                granularity: context.state.countdownGranularity,
                                ticking: .systemText
                            )
                                .font(.headline)
                                .monospacedDigit()
                        } else if let value = context.state.value {
                            HStack(spacing: 2) {
                                Text(value).font(.headline)
                                if let unit = context.state.unit {
                                    Text(unit).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        } else {
                            Text(context.state.state.capitalized)
                                .font(.headline)
                        }
                    }
                    .lineLimit(1)
                    // 0.6, matching `compactTrailing`. At 0.8 a countdown as
                    // ordinary as "~37 min" truncated to "~37…" — a clipped
                    // number on the one surface the whole activity exists to
                    // put a number on.
                    .minimumScaleFactor(0.6)
                    .padding(.trailing, 8)
                }
                // Deliberately empty. The centre region shares the top row
                // with the leading and trailing ones, around a camera housing
                // that takes the middle of it — so a subtitle of any length put
                // here is not a caption under a header, it is a third claimant
                // on the same width. A two-line one crushed the title to "Mar…"
                // and the countdown to "~37…" at the same time. The bottom
                // region spans the full width and is where prose belongs.
                DynamicIslandExpandedRegion(.center) {
                    EmptyView()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if !context.state.presentationItems.isEmpty {
                        VStack(spacing: 5) {
                            ForEach(Array(context.state.presentationItems.prefix(3))) { item in
                                LiveActivityItemRow(item: item, condensed: true)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 4)
                    } else {
                        VStack(alignment: .leading, spacing: 5) {
                            if let chart = context.state.chart, chart.isRenderable {
                                // Ranked above progress: a producer sending both
                                // has a number that moves, and the plot says
                                // which way while a bar only says how far.
                                SparklineView(chart: chart, tint: context.attributes.kind.tint(for: context.state.signal), lineWidth: 1.5)
                                    .frame(height: 26)
                            } else if let p = context.state.progress {
                                // Not gated on `endsAt == nil` any more. A
                                // deadline and a completion fraction are two
                                // facts, not two spellings of one: a four-part
                                // job with an ETA has both, and suppressing the
                                // bar left the 24pt minimal circle able to show
                                // completion — `minimalProgress` even derives it
                                // from a "1/4" written into `value` — while this
                                // region, with room for it, showed nothing.
                                ProgressView(value: max(0, min(p, 1)))
                                    .progressViewStyle(.linear)
                                    .tint(context.attributes.kind.tint(for: context.state.signal))
                            }
                            if let subtitle = context.state.subtitle {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 4)
                    }
                }
            } compactLeading: {
                IslandGlyph(systemName: islandIconName(attributes: context.attributes, state: context.state))
                    .foregroundStyle(context.attributes.kind.tint(for: context.state.signal))
                    .fixedSize()
            } compactTrailing: {
                // The compact trailing region is narrow, and it neither wraps
                // nor scales: it clips, from the *leading* edge, so "4/5"
                // arrives as "/5" and reads as a real value rather than as
                // truncation. Two things are needed together. `fixedSize()`
                // makes the region negotiate a width instead of accepting a
                // proposal too small for its content — without it even three
                // glyphs are cut, and the leading glyph is cut with them,
                // because the whole compact presentation is laid out against
                // that proposal. And `compactValueToken` bounds what may ask,
                // since a region free to demand its ideal width grows the
                // island across most of the screen and clips anyway.
                Group {
                    if context.state.showsItemCount {
                        Text("\(context.state.activeItems.count)")
                            .monospacedDigit()
                    } else if let endsAt = context.state.endsAt {
                        LiveActivityCountdownText(
                            endsAt: endsAt,
                            granularity: context.state.countdownGranularity,
                                ticking: .systemText
                        )
                        .monospacedDigit()
                    } else if let token = context.state.compactValueToken {
                        Text(token)
                            .font(.caption2)
                            .monospacedDigit()
                    } else if let p = context.state.progress {
                        Text("\(Int((max(0, min(p, 1)) * 100).rounded()))%")
                            .monospacedDigit()
                    } else if let token = ZeroZeroWidgetActivityAttributes.ContentState
                        .compactToken(context.state.state) {
                        Text(token)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .fixedSize()
            } minimal: {
                MinimalIslandView(
                    state: context.state,
                    tint: context.attributes.kind.tint(for: context.state.signal),
                    glyph: islandIconName(attributes: context.attributes, state: context.state)
                )
            }
            .widgetURL(tapURL(for: context.attributes))
        }
        // Opt the Live Activity into rendering as a Smart Stack card on Apple
        // Watch (.small) in addition to the iPhone Lock Screen (.medium).
        // LockScreenView reads \.activityFamily to pick the right layout.
        .supplementalActivityFamilies([.small, .medium])
    }

    private func iconName(
        attributes: ZeroZeroWidgetActivityAttributes,
        state: ZeroZeroWidgetActivityAttributes.ContentState
    ) -> String {
        state.icon ?? attributes.icon ?? iconName(for: attributes.kind)
    }

    /// A producer URL wins. The full app's widget target supplies an internal
    /// Activities-tab URL as its fallback; the App Clip extension deliberately
    /// omits that setting because the clip has no tab bar.
    private func tapURL(for attributes: ZeroZeroWidgetActivityAttributes) -> URL? {
        attributes.deepLink ?? ZeroZeroWidgetConstants.liveActivityFallbackURL
    }

    private func iconName(for kind: LiveActivityKind) -> String {
        switch kind {
        case .generic: return "square.dashed"
        case .progress: return "chart.bar"
        case .charging: return "bolt.car"
        case .appliance: return "washer"
        case .job: return "hammer"
        case .timer: return "timer"
        }
    }

    /// The Dynamic Island's identity glyph. A producer's own icon still wins,
    /// as it does everywhere else; only the fallback differs from the Lock
    /// Screen's, because the island's regions are round and about 24pt across.
    private func islandIconName(
        attributes: ZeroZeroWidgetActivityAttributes,
        state: ZeroZeroWidgetActivityAttributes.ContentState
    ) -> String {
        state.icon ?? attributes.icon ?? islandIconName(for: attributes.kind)
    }

    /// Fitting a symbol into the island's circle trades width for height, so a
    /// wide default becomes a short one. `bolt.car` is nearly 2:1 and survives
    /// that badly; the filled variants are chosen for weight rather than shape,
    /// which is what keeps them legible once fitted. The three kinds not listed
    /// are already square enough to use their Lock Screen glyph unchanged.
    private func islandIconName(for kind: LiveActivityKind) -> String {
        switch kind {
        case .charging: return "bolt.fill"
        case .job: return "hammer.fill"
        case .progress: return "chart.bar.fill"
        case .generic, .appliance, .timer: return iconName(for: kind)
        }
    }
}

/// A glyph for the compact and minimal Dynamic Island regions.
///
/// Those regions clip rather than shrink, and `minimumScaleFactor` is text
/// only, so a symbol laid out at the inherited font size overruns them
/// horizontally whenever it is wider than it is tall — which `hammer` is, and
/// `bolt.car` badly is. Producers may send any symbol name they like, so the
/// widest dimension is fitted into a square instead of trusting the symbol's
/// aspect ratio. `.resizable()` costs the glyph its text-baseline alignment,
/// which does not matter where it is the only thing in the region.
private struct IslandGlyph: View {
    let systemName: String
    var size: CGFloat = 16

    var body: some View {
        Image(systemName: systemName)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }
}

/// The island's minimal presentation: one circle about 24pt across, which the
/// system substitutes for *both* compact regions the moment a second Live
/// Activity starts — anyone's, including Screen Recording. There is no API to
/// decline it, no way to influence which two activities are shown, and nothing
/// that says what we are sharing the island with. The only thing under our
/// control is what goes in the circle.
///
/// So: state first, identity last. The app icon sits beside this circle and
/// `kind.tint` colours everything inside it, which means a glyph spends the
/// one surface left on the thing the operator already knows. Each rung takes
/// the most informative token that fits, and the glyph is what remains when
/// the activity genuinely has nothing to say. `endsAt` leads because it was
/// the one case that rendered no information at all — a deadline drew a static
/// glyph while the compact region it replaced had been counting down.
private struct MinimalIslandView: View {
    let state: ZeroZeroWidgetActivityAttributes.ContentState
    let tint: Color
    let glyph: String

    @ViewBuilder
    var body: some View {
        if let endsAt = state.endsAt {
            LiveActivityCountdownToken(endsAt: endsAt, granularity: state.countdownGranularity)
                .minimalIslandToken(tint: tint)
        } else if let progress = state.minimalProgress {
            // The label sits inside the capacity ring rather than filling the
            // circle, so it gets less room than the bare glyph beside it.
            Gauge(value: progress) {
                IslandGlyph(systemName: glyph, size: 10)
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(tint)
        } else if state.showsItemCount {
            Text("\(state.activeItems.count)")
                .minimalIslandToken(tint: tint)
        } else if let token = state.minimalValueToken {
            Text(token)
                .minimalIslandToken(tint: tint)
        } else {
            IslandGlyph(systemName: glyph)
                .foregroundStyle(tint)
        }
    }
}

private extension View {
    /// Text in the minimal circle. The region clips rather than shrinks, and it
    /// clips from the leading edge — the trap `compactTrailing` documents, in a
    /// third of the width. The tint is what keeps identity when the glyph that
    /// usually carries it has given up its place to a number.
    func minimalIslandToken(tint: Color) -> some View {
        font(.caption2)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .foregroundStyle(tint)
    }
}

private struct LockScreenView: View {
    let attributes: ZeroZeroWidgetActivityAttributes
    let state: ZeroZeroWidgetActivityAttributes.ContentState
    /// ActivityKit's own verdict, from the `staleDate` on `ActivityContent`.
    /// Taken *in addition to* `state.isStale` rather than instead of it: the
    /// system's flag is exact and arrives with a redraw, but it exists only
    /// for a producer that sent `staleAt`, and the ones worth worrying about
    /// are disproportionately the ones that did not.
    let systemIsStale: Bool

    // .small covers every compact renderer of this activity — the Apple Watch
    // Smart Stack, and from iOS 27 the CarPlay Dashboard and the macOS menu
    // bar as well. .medium is the iPhone Lock Screen.
    @Environment(\.activityFamily) private var activityFamily

    private var tint: Color { attributes.kind.tint(for: state.signal) }

    var body: some View {
        Group {
            switch activityFamily {
            case .small:
                smallBody
            default:
                lockScreenBody
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilitySummary))
    }

    private var isStale: Bool { systemIsStale || state.isStale }

    private var accessibilitySummary: String {
        LiveActivityAccessibilitySummary.summary(
            title: attributes.title,
            state: state.state,
            signal: state.signal,
            value: state.value,
            unit: state.unit,
            progress: state.progress,
            subtitle: state.subtitle,
            activeItemCount: state.activeItems.count,
            isStale: isStale
        )
    }

    /// The line that says the producer went quiet.
    ///
    /// It is the only thing on this surface that can, and until now nothing
    /// did: `isStale` was computed for the VoiceOver summary and drawn
    /// nowhere, so a blind user was told an activity had stopped updating and
    /// a sighted one went on reading its last numbers as current. A Live
    /// Activity is rebuilt only when its content state changes, which makes a
    /// producer that has stopped sending exactly the case no redraw is coming
    /// for — hence the clock inside `FreshnessLine`.
    private var freshness: some View {
        FreshnessLine(
            updatedAt: state.updatedAt,
            isStale: { isStale },
            font: .caption2,
            spacing: 4,
            ticking: .systemText
        )
    }

    private var lockScreenBody: some View {
        Group {
            if state.presentationItems.isEmpty {
                legacyLockScreenBody
            } else {
                compositeLockScreenBody
            }
        }
        .padding()
        // Width only. `maxHeight: .infinity` was here while the wash was a
        // `.background` that had to be stretched to cover the banner;
        // `containerBackground` fills the container whatever the content does,
        // and an unbounded height proposal is the one thing that would stop
        // `ViewThatFits` above from ever choosing a shorter candidate.
        .frame(maxWidth: .infinity, alignment: .leading)
        // `containerBackground`, not `.background`. A `.background` is sized to
        // the view it modifies, and the system's banner is taller and wider
        // than our padded content — so the wash stopped short of the capsule on
        // every side and the flat `activityBackgroundTint` showed beyond it, a
        // visible band across the top and bottom of the Lock Screen banner.
        //
        // This is also what replaces the `showsWidgetContainerBackground` check
        // that used to guard it. The system removes a container background
        // itself where it wants one gone — StandBy, which enlarges the Lock
        // Screen layout to 200% and draws no container of its own — so the rule
        // the old comment described is now enforced by the API rather than
        // restated here.
        .containerBackground(for: .widget) {
            LiveActivityBackground.gradient(for: attributes.kind, signal: state.signal)
        }
    }

    /// The composite banner, at whichever density fits the height the system
    /// gave us.
    ///
    /// A Lock Screen banner has a fixed maximum height, and a `VStack` handed
    /// less room than it needs does not compress — it *centres* and overflows,
    /// which clipped this layout's header off the top and its freshness line
    /// off the bottom at the same time. Nothing in a build, a test, or a
    /// screenshot of any other activity could see it: the overflow only appears
    /// once an activity carries enough rows, and every sample until now carried
    /// none. It is the same fact that decides the row caps in `TVDetailView`,
    /// arriving on the other platform.
    ///
    /// `ViewThatFits` rather than a hardcoded row count, because the number
    /// depends on the device, on Dynamic Type, and on whether the rows carry
    /// subtitles or progress bars — none of which this can measure and all of
    /// which the layout engine already knows. It takes the first candidate
    /// whose ideal height fits, so the ordering below is "most informative
    /// first" and the last one is the floor that must always fit. Every row
    /// count the API accepts is offered: starting this ladder at three looked
    /// adaptive but made three a hard ceiling, so a roomier banner could never
    /// prove that a fourth, fifth, or sixth item fit.
    private var compositeLockScreenBody: some View {
        ViewThatFits(in: .vertical) {
            composite(rows: 6, condensed: false)
            composite(rows: 6, condensed: true)
            composite(rows: 5, condensed: false)
            composite(rows: 5, condensed: true)
            composite(rows: 4, condensed: false)
            composite(rows: 4, condensed: true)
            composite(rows: 3, condensed: false)
            // Rows before subtitles. Which parts a job has is the thing the
            // banner is for; a row's subtitle is a detail of one of them, and
            // dropping three subtitles to keep a third part on screen trades
            // less than dropping the part does.
            composite(rows: 3, condensed: true)
            composite(rows: 2, condensed: false)
            composite(rows: 2, condensed: true)
            composite(rows: 1, condensed: true)
        }
    }

    private func composite(rows: Int, condensed: Bool) -> some View {
        let presentationItems = state.presentationItems
        let shown = Array(presentationItems.prefix(rows))
        let hidden = presentationItems.count - shown.count
        return VStack(alignment: .leading, spacing: condensed ? 5 : 7) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                statusGlyph(.subheadline)
                Text(attributes.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if state.hasExplicitValue, let value = state.value {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(value)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if let unit = state.unit {
                            Text(unit)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("\(state.activeItems.count) active")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(shown) { item in
                LiveActivityItemRow(item: item, condensed: condensed)
            }
            // One line, not two. Both are trailing metadata and neither fills
            // its own width, so pairing them buys back a whole row of item —
            // which is the difference between showing three parts of a job and
            // two.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if hidden > 0 {
                    Text("+\(hidden) more")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                freshness
            }
        }
    }

    private var legacyLockScreenBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 3) {
                    Image(systemName: iconName)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    statusGlyph(.caption)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(attributes.title).font(.headline)
                    if let subtitle = state.subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    if let endsAt = state.endsAt {
                        LiveActivityCountdownText(
                            endsAt: endsAt,
                            granularity: state.countdownGranularity,
                                ticking: .systemText
                        )
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    // Not an `else`. "How long is left" and "how much is done"
                    // are different questions, and a job that can answer both
                    // was answering neither here — the bar was suppressed by
                    // the deadline, and the deadline is an estimate while the
                    // fraction is a count. The chart still wins, because it
                    // says which way the number is going rather than how far.
                    if let p = state.progress, state.chart == nil {
                        ProgressView(value: max(0, min(p, 1)))
                            .progressViewStyle(.linear)
                            .tint(tint)
                    }
                }
                Spacer()
                // An explicit producer value is more useful than the generic
                // runtime state, even when the activity also has a deadline.
                if let value = state.value {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(value).font(.title3).fontWeight(.semibold)
                        if let unit = state.unit {
                            Text(unit).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text(state.state.capitalized)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.secondary.opacity(0.2)))
                }
            }

            // Keep the identity column clear while allowing the plot to use
            // the space beneath the trailing value/status presentation.
            if let chart = state.chart, chart.isRenderable {
                SparklineView(chart: chart, tint: tint, lineWidth: 1.5)
                    .frame(height: 24)
                    .padding(.leading, 44)
            }

            freshness
                .padding(.leading, 44)
        }
    }

    /// One layout for every `.small` renderer, sized by the width it is given.
    ///
    /// Apple Watch and the CarPlay Dashboard share this family and nothing in
    /// the environment separates them, so width is the only signal available.
    /// A watch card is around 180pt across; a Dashboard cell is far wider and
    /// is read at arm's length from a driving position, where the watch's
    /// `.caption2`/`.headline` pairing is too small to be glanceable.
    private var smallBody: some View {
        GeometryReader { proxy in
            smallContent(SmallActivityMetrics.forWidth(proxy.size.width))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private func smallContent(_ metrics: SmallActivityMetrics) -> some View {
        HStack(spacing: metrics.spacing) {
            SmallActivityIdentity(
                glyph: iconName,
                progress: smallProgress,
                tint: tint,
                metrics: metrics
            )
            statusGlyph(metrics.statusGlyph)
            VStack(alignment: .leading, spacing: 1) {
                Text(attributes.title)
                    .font(metrics.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !state.hasExplicitValue, let item = state.activeItems.first {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Image(systemName: item.icon ?? "circle.fill")
                            .font(metrics.caption)
                            .foregroundStyle(item.tint())
                        SemanticFlowIcon(item.semantic, font: metrics.caption)
                        Text(item.value ?? item.title)
                            .font(metrics.value)
                            .lineLimit(1)
                        if let unit = item.unit, item.value != nil {
                            Text(unit).font(metrics.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    primarySmallValue(metrics)
                }
            }
            Spacer(minLength: 0)
            if state.showsItemCount, state.activeItems.count > 1 {
                Text("\(state.activeItems.count)")
                    .font(metrics.value)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, metrics.horizontalPadding)
        .padding(.vertical, metrics.verticalPadding)
    }

    /// The fraction the identity ring draws, or `nil` for a bare glyph.
    ///
    /// The first active item's own progress still wins, because a composite
    /// activity's current part is the thing being watched. Below that this now
    /// reads `minimalProgress` rather than `progress` alone: the ladder there
    /// derives a fraction from finished items or from a counter written into
    /// `value`, and refuses to invent a zero. A `.small` card is seven times
    /// the area of the Dynamic Island's minimal circle and was showing strictly
    /// less completion than it — nothing at all wherever the producer counted
    /// in items or in prose.
    private var smallProgress: Double? {
        if let p = state.activeItems.first?.progress { return max(0, min(p, 1)) }
        return state.minimalProgress
    }

    @ViewBuilder
    private func primarySmallValue(_ metrics: SmallActivityMetrics) -> some View {
        if let endsAt = state.endsAt {
            LiveActivityCountdownText(
                endsAt: endsAt,
                granularity: state.countdownGranularity,
                                ticking: .systemText
            )
                .font(metrics.value)
                .monospacedDigit()
                .lineLimit(1)
        } else if let value = state.value {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(metrics.value).lineLimit(1)
                if let unit = state.unit {
                    Text(unit).font(metrics.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            Text(state.state.capitalized)
                .font(metrics.state)
                .lineLimit(1)
        }
    }

    /// The runtime glyph beside the identity icon: what the activity is doing
    /// right now, as opposed to what it is.
    ///
    /// Drawn in `.primary` against the identity icon's `.secondary`, because
    /// the moving thing is the one worth the eye. Deliberately absent from the
    /// compact and minimal Dynamic Island regions — they are a few points wide,
    /// and a second glyph there would crowd out the value.
    @ViewBuilder
    private func statusGlyph(_ font: Font) -> some View {
        if let statusIcon = state.statusIcon ?? state.signal?.symbolName {
            Image(systemName: statusIcon)
                .font(font)
                .foregroundStyle(tint)
        }
    }

    private var iconName: String {
        if let icon = state.icon ?? attributes.icon {
            return icon
        }
        switch attributes.kind {
        case .generic: return "square.dashed"
        case .progress: return "chart.bar"
        case .charging: return "bolt.car"
        case .appliance: return "washer"
        case .job: return "hammer"
        case .timer: return "timer"
        }
    }
}

/// The ground a Live Activity is drawn on.
///
/// `activityBackgroundTint` is what StandBy shows. It reuses the Lock Screen
/// layout at 200% on a charging iPhone in landscape and draws no container of
/// its own, so the tint runs edge to edge across a bedside display — where a
/// flat 60% black filled the space with a slab carrying no identity at all.
/// The tint now mixes the activity's own accent into a dark ground the white
/// `activitySystemActionForegroundColor` stays legible against.
enum LiveActivityBackground {
    static func tint(for kind: LiveActivityKind, signal: MetricSignal? = nil) -> Color {
        // Mostly ground, a little accent: enough to tell a charging session
        // from a running job at a glance across a room, not enough to fight
        // the foreground.
        Color.black.mix(with: kind.tint(for: signal), by: 0.16).opacity(0.72)
    }

    /// Drawn only where the system provides a container. Apple's guidance is
    /// that an inset background of our own looks stranded once StandBy
    /// enlarges it, so there this is omitted and `tint(for:)` stands alone.
    static func gradient(for kind: LiveActivityKind, signal: MetricSignal? = nil) -> LinearGradient {
        LinearGradient(
            colors: [kind.tint(for: signal).opacity(0.16), .clear],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

/// The `.small` family's leading element: identity and completion in one
/// circle, or the bare glyph when there is no honest fraction to draw.
///
/// These were two views side by side, and on a watch card that is most of the
/// width. `Gauge(.accessoryCircularCapacity)` reports a **fixed 58×58**
/// whatever it is proposed and whatever the Dynamic Type size — measured, not
/// assumed — and the old `.scaleEffect(0.8)` beside it did not change that,
/// because `scaleEffect` is a draw-time transform with no effect on layout. So
/// the row spent 58 points on a ring drawn at 46, plus 29 on a `.title3` glyph
/// and a spacing between them, and on the narrowest watch card that left the
/// title and value column about 21 points: "Configure release" rendered as
/// "Confi…" over "Push…". Composing them recovers all of it, and the glyph
/// inside the ring is the arrangement `MinimalIslandView` already uses.
///
/// `scaleEffect` *and* `frame` together, therefore: the frame is what the row
/// budgets, the scale is what makes the drawing match it. Either alone is
/// wrong in a different direction — frame alone lays out 34 points and draws
/// 58 through its neighbours, scale alone draws 34 and reserves 58.
private struct SmallActivityIdentity: View {
    let glyph: String
    let progress: Double?
    let tint: Color
    let metrics: SmallActivityMetrics

    /// The intrinsic size of `.accessoryCircularCapacity`, which honours no
    /// proposal. Verified stable from `.large` through `.accessibility5`.
    private static let gaugeIntrinsicSize: CGFloat = 58

    var body: some View {
        if let progress {
            Gauge(value: max(0, min(progress, 1))) {
                // Fitted into a square for the reason `IslandGlyph` documents:
                // a producer may send any symbol, and a wide one laid out at a
                // font size overruns a circle sized for a square.
                IslandGlyph(systemName: glyph, size: metrics.ringSize * 0.36)
            }
            .gaugeStyle(.accessoryCircularCapacity)
            // The ring carried no tint at all, which is why it drew grey on a
            // card where everything else took `kind.tint`. `MinimalIslandView`
            // has always tinted its gauge; this is the same ring.
            .tint(tint)
            .scaleEffect(metrics.ringSize / Self.gaugeIntrinsicSize)
            .frame(width: metrics.ringSize, height: metrics.ringSize)
        } else {
            Image(systemName: glyph)
                .font(metrics.icon)
                .foregroundStyle(.secondary)
        }
    }
}

/// Type, spacing, and padding for the `.small` activity family.
///
/// Two presets rather than a continuous scale: the family renders on a small
/// number of very different surfaces, and a set of sizes each chosen to read
/// well beats interpolating between them.
private struct SmallActivityMetrics {
    var icon: Font
    var statusGlyph: Font
    var caption: Font
    var value: Font
    var state: Font
    var spacing: CGFloat
    var horizontalPadding: CGFloat
    var verticalPadding: CGFloat
    /// The identity ring's laid-out diameter. See `SmallActivityIdentity` for
    /// why this is a size rather than the scale factor it replaced.
    var ringSize: CGFloat

    /// Comfortably above the widest Apple Watch Smart Stack card and below the
    /// narrowest CarPlay Dashboard cell. A container that reports no width yet
    /// falls to `tight`, which is the layout this family had before CarPlay.
    static let roomyWidthThreshold: CGFloat = 260

    static func forWidth(_ width: CGFloat) -> SmallActivityMetrics {
        width >= roomyWidthThreshold ? .roomy : .tight
    }

    static let tight = SmallActivityMetrics(
        icon: .title3,
        statusGlyph: .caption,
        caption: .caption2,
        value: .headline,
        state: .subheadline,
        spacing: 8,
        horizontalPadding: 10,
        verticalPadding: 6,
        ringSize: 34
    )

    /// Everything a step up, and a larger ring: this is read from a driving
    /// position rather than a raised wrist.
    static let roomy = SmallActivityMetrics(
        icon: .title2,
        statusGlyph: .subheadline,
        caption: .caption,
        value: .title3,
        state: .headline,
        spacing: 12,
        horizontalPadding: 16,
        verticalPadding: 10,
        ringSize: 48
    )
}

private struct LiveActivityItemRow: View {
    let item: LiveActivityItem
    var condensed = false
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        VStack(spacing: condensed ? 2 : 3) {
            HStack(spacing: 7) {
                Image(systemName: item.icon ?? "circle.fill")
                    .font(condensed ? .caption2 : .caption)
                    .frame(width: 14)
                    .foregroundStyle(item.tint())
                if let statusIcon = item.statusIcon {
                    Image(systemName: statusIcon)
                        .font(.caption2)
                        .foregroundStyle(.primary)
                }
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 3) {
                        SemanticFlowIcon(item.semantic, font: .caption2)
                        Text(item.title)
                            .font(condensed ? .caption2 : .caption.weight(.semibold))
                            .lineLimit(1)
                    }
                    if !condensed, let subtitle = item.subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if let value = item.value {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(value)
                            .font(condensed ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                            .lineLimit(1)
                        if let unit = item.unit {
                            Text(unit)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                } else if let status = item.status {
                    Text(status.label)
                        .font(.caption2)
                        .foregroundStyle(
                            VisualAccommodations.textTint(
                                status.tint,
                                increasedContrast: colorSchemeContrast == .increased
                            )
                        )
                        .lineLimit(1)
                }
            }
            if let progress = item.progress {
                ProgressView(value: max(0, min(progress, 1)))
                    .progressViewStyle(.linear)
                    .tint(item.tint())
            }
        }
    }
}
