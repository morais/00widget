package com.example.zerozerowidget.hzos.data

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Kotlin mirror of the 00Widget wire model.
 *
 * Source of truth lives in two places already — `server/src/types.ts` (zod)
 * and `ios/Sources/Shared/Models/` (Swift) — and this file is the third
 * copy by the same "duplicated by design" rule. When a field is added to
 * [DashboardCard], edit all three in the same change.
 *
 * Unknown enum values fall back rather than failing the whole list decode,
 * mirroring the Swift decoders: one card from a newer server must not take
 * the dashboard down with it.
 */

@Serializable
enum class DashboardTemplate(val raw: String) {
    @SerialName("summary") SUMMARY("summary"),
    @SerialName("progress") PROGRESS("progress"),
    @SerialName("list") LIST("list"),
    @SerialName("action") ACTION("action"),
    @SerialName("chart") CHART("chart"),
    @SerialName("history") HISTORY("history"),
    @SerialName("breakdown") BREAKDOWN("breakdown"),
    @SerialName("briefing") BRIEFING("briefing"),
    @SerialName("timeline") TIMELINE("timeline"),
    ;

    companion object {
        fun orSummary(raw: String?): DashboardTemplate =
            values().firstOrNull { it.raw == raw } ?: SUMMARY
    }
}

@Serializable
enum class DashboardStatus(val raw: String) {
    @SerialName("unknown") UNKNOWN("unknown"),
    @SerialName("good") GOOD("good"),
    @SerialName("warning") WARNING("warning"),
    @SerialName("critical") CRITICAL("critical"),
    @SerialName("running") RUNNING("running"),
    @SerialName("finished") FINISHED("finished"),
    @SerialName("paused") PAUSED("paused"),
    @SerialName("offline") OFFLINE("offline"),
    ;

    companion object {
        fun orUnknown(raw: String?): DashboardStatus =
            values().firstOrNull { it.raw == raw } ?: UNKNOWN
    }
}

@Serializable
data class CardProducer(
    val label: String,
    val icon: String? = null,
)

@Serializable
data class CardComparison(
    val value: String,
    val label: String,
    val signal: String = "neutral",
)

@Serializable
data class DashboardItemSemantic(
    val role: String? = null,
    val flow: String? = null,
)

@Serializable
data class DashboardItem(
    val id: String,
    val title: String,
    val subtitle: String? = null,
    val value: String? = null,
    val unit: String? = null,
    val status: DashboardStatus = DashboardStatus.UNKNOWN,
    val semantic: DashboardItemSemantic? = null,
    val deepLink: String? = null,
    val amount: Double? = null,
)

@Serializable
data class MetricSemantic(
    val role: String? = null,
    val flow: String? = null,
    val signal: String? = null,
)

@Serializable
data class DashboardChartCategory(
    val id: String,
    val label: String,
    val signal: String? = null,
)

@Serializable
data class DashboardChartSeries(
    val id: String,
    val label: String,
    val points: List<Double>,
    val semantic: MetricSemantic? = null,
)

@Serializable
data class DashboardChartRange(
    val low: Double,
    val high: Double,
    val value: Double? = null,
)

@Serializable
data class ChartReferenceMetadata(
    val label: String? = null,
    val semantic: MetricSemantic? = null,
)

@Serializable
data class DashboardChart(
    val points: List<Double>,
    val min: Double? = null,
    val max: Double? = null,
    val reference: Double? = null,
    val referenceMetadata: ChartReferenceMetadata? = null,
    val semantic: MetricSemantic? = null,
    val style: String = "line",
    val labels: List<String>? = null,
    val categories: List<DashboardChartCategory>? = null,
    val series: List<DashboardChartSeries>? = null,
    val ranges: List<DashboardChartRange>? = null,
    val rangeValueLabel: String? = null,
    val stacking: String = "stacked",
)

@Serializable
data class BriefingSection(
    val id: String,
    val label: String? = null,
    val text: String,
)

@Serializable
data class DashboardBriefing(
    val sections: List<BriefingSection>,
)

@Serializable
data class TimelineLane(
    val id: String,
    val label: String,
)

@Serializable
data class TimelineSeries(
    val id: String,
    val label: String,
    val icon: String? = null,
)

@Serializable
data class TimelineEntry(
    val id: String,
    val laneId: String,
    val seriesId: String,
    val at: String,
    val endAt: String? = null,
    val label: String? = null,
    val status: DashboardStatus = DashboardStatus.UNKNOWN,
)

@Serializable
data class DashboardTimeline(
    val startAt: String,
    val endAt: String,
    val lanes: List<TimelineLane>,
    val series: List<TimelineSeries>,
    val entries: List<TimelineEntry>,
)

@Serializable
data class ActionDefinition(
    val id: String,
    val label: String,
    val role: String = "normal",
    val confirm: Boolean = false,
) {
    /**
     * Mirrors `ActionDefinition.isSafeFromWidget` on iOS: only normal,
     * no-confirm actions may run straight from a panel. Anything else must
     * route through a confirmation surface (here: the detail panel), never
     * by loosening this check.
     */
    val isSafeFromPanel: Boolean get() = role == "normal" && !confirm
}

@Serializable
data class DashboardCard(
    val id: String,
    val template: DashboardTemplate,
    val title: String,
    val subtitle: String? = null,
    val value: String? = null,
    val unit: String? = null,
    val status: DashboardStatus = DashboardStatus.UNKNOWN,
    val icon: String? = null,
    val statusIcon: String? = null,
    val producer: CardProducer? = null,
    val comparison: CardComparison? = null,
    val priority: Int? = null,
    val progress: Double? = null,
    val updatedAt: String? = null,
    val staleAfter: String? = null,
    val deadline: String? = null,
    val deepLink: String? = null,
    val items: List<DashboardItem>? = null,
    val chart: DashboardChart? = null,
    val timeline: DashboardTimeline? = null,
    val briefing: DashboardBriefing? = null,
    val actions: List<ActionDefinition>? = null,
) {
    /** Server returns cards pre-sorted; keep that order, it encodes priority. */
    companion object {
        fun sorted(cards: List<DashboardCard>): List<DashboardCard> = cards
    }
}

@Serializable
data class LiveActivityItem(
    val id: String,
    val title: String,
    val subtitle: String? = null,
    val icon: String? = null,
    val statusIcon: String? = null,
    val value: String? = null,
    val unit: String? = null,
    val progress: Double? = null,
    val status: DashboardStatus = DashboardStatus.UNKNOWN,
    val semantic: DashboardItemSemantic? = null,
)

@Serializable
data class LiveActivitySession(
    val activityInstanceId: String? = null,
    val externalActivityId: String,
    val kind: String = "generic",
    val title: String,
    val subtitle: String? = null,
    val state: String = "",
    val signal: String? = null,
    val icon: String? = null,
    val statusIcon: String? = null,
    val value: String? = null,
    val unit: String? = null,
    val progress: Double? = null,
    val items: List<LiveActivityItem>? = null,
    val chart: DashboardChart? = null,
    val endsAt: String? = null,
    val updatedAt: String? = null,
    val staleAt: String? = null,
    val deepLink: String? = null,
)

@Serializable
data class CardsListResponse(val cards: List<DashboardCard> = emptyList())

@Serializable
data class LiveActivitiesListResponse(val activities: List<LiveActivitySession> = emptyList())

@Serializable
data class DashboardResponse(
    val cards: List<DashboardCard> = emptyList(),
    val activities: List<LiveActivitySession> = emptyList(),
)

@Serializable
data class ActionRunContext(val cardId: String? = null)

@Serializable
data class ActionRunBody(val context: ActionRunContext)
