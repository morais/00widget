package com.example.zerozerowidget.hzos.ui.cards

import androidx.compose.ui.graphics.Color
import com.example.zerozerowidget.hzos.data.DashboardStatus
import com.example.zerozerowidget.hzos.data.MetricSemantic

/**
 * The iOS renderer's color system, ported verbatim.
 *
 * Sources: `DashboardStatus.tint`, `MetricSignal.tint`,
 * `ChartSeriesPalette` (tint / seriesTints / opacity / referenceDash) in
 * ios/Sources/Shared. iOS names UIKit system colors; the hex below is their
 * dark-mode values, so both platforms draw the same pixels. Keep the two in
 * lockstep: a palette change over there means a palette change here.
 */
object IosChartColors {
    val BLUE = Color(0xFF0A84FF)
    val PURPLE = Color(0xFFBF5AF2)
    val TEAL = Color(0xFF40C8E0)
    val ORANGE = Color(0xFFFF9F0A)
    val GREEN = Color(0xFF30D158)
    val RED = Color(0xFFFF453A)
    val SECONDARY = Color(0xFF98989D)
}

/** Mirrors DashboardStatus.tint (good/finished share green, etc.). */
fun statusColor(status: DashboardStatus, unknown: Color): Color = when (status) {
    DashboardStatus.GOOD -> IosChartColors.GREEN
    DashboardStatus.FINISHED -> IosChartColors.GREEN
    DashboardStatus.WARNING -> IosChartColors.ORANGE
    DashboardStatus.PAUSED -> IosChartColors.ORANGE
    DashboardStatus.CRITICAL -> IosChartColors.RED
    DashboardStatus.RUNNING -> IosChartColors.BLUE
    DashboardStatus.OFFLINE -> IosChartColors.SECONDARY
    DashboardStatus.UNKNOWN -> unknown
}

/** Mirrors MetricSignal.tint. Null (no signal) falls back to [base]. */
fun signalColor(signal: String?, base: Color): Color = when (signal) {
    "favorable" -> IosChartColors.GREEN
    "neutral" -> IosChartColors.SECONDARY
    "caution" -> IosChartColors.ORANGE
    "unfavorable" -> IosChartColors.RED
    else -> base
}

/** Flow hint color, or null when the semantic carries no flow. */
fun flowColor(flow: String?): Color? = when (flow) {
    "inbound" -> IosChartColors.TEAL
    "outbound" -> IosChartColors.PURPLE
    else -> null
}

/**
 * Mirrors ChartSeriesPalette.tint(index:base:semantic:): signal wins, then
 * flow, then the per-index fallback (base, purple, teal, orange).
 */
fun chartTint(index: Int, base: Color, semantic: MetricSemantic?): Color {
    semantic?.signal?.let { return signalColor(it, base) }
    flowColor(semantic?.flow)?.let { return it }
    return when (index) {
        0 -> base
        1 -> IosChartColors.PURPLE
        2 -> IosChartColors.TEAL
        3 -> IosChartColors.ORANGE
        else -> IosChartColors.SECONDARY
    }
}

/**
 * Mirrors ChartSeriesPalette.seriesTints: semantic preference first
 * (signal, else flow), then rotation through blue/purple/teal/orange with
 * dedup so stacked segments stay distinguishable.
 */
fun seriesTints(semantics: List<MetricSemantic?>): List<Color> {
    val defaults = listOf(
        IosChartColors.BLUE,
        IosChartColors.PURPLE,
        IosChartColors.TEAL,
        IosChartColors.ORANGE,
    )
    val used = mutableSetOf<Color>()
    return semantics.mapIndexed { index, semantic ->
        val preferred: Color? = semantic?.signal?.let { signalColor(it, IosChartColors.SECONDARY) }
            .takeIf { semantic?.signal != null }
            ?: flowColor(semantic?.flow)
        val rotated = (0 until defaults.size).map { defaults[(index + it) % defaults.size] }
        val token = (listOfNotNull(preferred) + rotated).first { it !in used }
        used.add(token)
        token
    }
}

/**
 * Mirrors ChartSeriesPalette.opacity(for:): alpha encodes role. Actual and
 * unhinted series draw nearly solid; forecasts, capacities and remainders
 * wash out.
 */
fun roleOpacity(role: String?): Float = when (role) {
    "forecast" -> 0.48f
    "baseline" -> 0.55f
    "target" -> 0.72f
    "capacity" -> 0.35f
    "remainder" -> 0.45f
    else -> 0.88f
}

/** Mirrors ChartSeriesPalette.referenceDash(for:). iOS points → px here. */
fun referenceDash(role: String?): FloatArray = when (role) {
    "baseline" -> floatArrayOf(4f, 12f)
    "capacity" -> floatArrayOf(24f, 8f)
    else -> floatArrayOf(12f, 12f)
}

/** Mirrors LiveActivityKind.tint: the activity accent by kind, then signal. */
fun activityTint(kind: String, signal: String?, accent: Color): Color {
    signal?.let { return signalColor(it, accent) }
    return when (kind) {
        "charging" -> IosChartColors.GREEN
        "appliance", "progress" -> IosChartColors.BLUE
        "job", "timer" -> IosChartColors.ORANGE
        else -> accent
    }
}
