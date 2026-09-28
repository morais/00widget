package com.zerozerowidget.hzos.ui.cards

import androidx.compose.ui.graphics.Color
import com.zerozerowidget.hzos.data.DashboardStatus
import com.zerozerowidget.hzos.data.MetricSemantic

/**
 * The iOS renderer's color system, ported verbatim.
 *
 * Sources: `DashboardStatus.tint`, `MetricSignal.tint`,
 * `ChartSeriesPalette` (tint / seriesTints / opacity / referenceDash) in
 * ios/Sources/Shared. iOS names UIKit system colors, which resolve per
 * mode; the two objects below are their dark and light values, so both
 * platforms draw the same pixels in either mode. Keep all three in
 * lockstep: a palette change over there means a palette change here.
 */
interface ChartPalette {
    val BLUE: Color
    val PURPLE: Color
    val TEAL: Color
    val ORANGE: Color
    val GREEN: Color
    val RED: Color
    val SECONDARY: Color
}

object IosChartColors : ChartPalette {
    override val BLUE = Color(0xFF0A84FF)
    override val PURPLE = Color(0xFFBF5AF2)
    override val TEAL = Color(0xFF40C8E0)
    override val ORANGE = Color(0xFFFF9F0A)
    override val GREEN = Color(0xFF30D158)
    override val RED = Color(0xFFFF453A)
    override val SECONDARY = Color(0xFF98989D)
}

/** iOS light-mode system colors, mirroring the dark set above. */
object IosChartColorsLight : ChartPalette {
    override val BLUE = Color(0xFF007AFF)
    override val PURPLE = Color(0xFFAF52DE)
    override val TEAL = Color(0xFF5AC8FA)
    override val ORANGE = Color(0xFFFF9500)
    override val GREEN = Color(0xFF34C759)
    override val RED = Color(0xFFFF3B30)
    override val SECONDARY = Color(0xFF8E8E93)
}

/** Picks the palette for the current theme. Call sites pass `dark` explicitly. */
fun chartPalette(dark: Boolean): ChartPalette = if (dark) IosChartColors else IosChartColorsLight

/** Mirrors DashboardStatus.tint (good/finished share green, etc.). */
fun statusColor(status: DashboardStatus, unknown: Color, dark: Boolean): Color {
    val palette = chartPalette(dark)
    return when (status) {
        DashboardStatus.GOOD -> palette.GREEN
        DashboardStatus.FINISHED -> palette.GREEN
        DashboardStatus.WARNING -> palette.ORANGE
        DashboardStatus.PAUSED -> palette.ORANGE
        DashboardStatus.CRITICAL -> palette.RED
        DashboardStatus.RUNNING -> palette.BLUE
        DashboardStatus.OFFLINE -> palette.SECONDARY
        DashboardStatus.UNKNOWN -> unknown
    }
}

/** Mirrors MetricSignal.tint. Null (no signal) falls back to [base]. */
fun signalColor(signal: String?, base: Color, dark: Boolean): Color {
    val palette = chartPalette(dark)
    return when (signal) {
        "favorable" -> palette.GREEN
        "neutral" -> palette.SECONDARY
        "caution" -> palette.ORANGE
        "unfavorable" -> palette.RED
        else -> base
    }
}

/** Flow hint color, or null when the semantic carries no flow. */
fun flowColor(flow: String?, dark: Boolean): Color? {
    val palette = chartPalette(dark)
    return when (flow) {
        "inbound" -> palette.TEAL
        "outbound" -> palette.PURPLE
        else -> null
    }
}

/**
 * Mirrors ChartSeriesPalette.tint(index:base:semantic:): signal wins, then
 * flow, then the per-index fallback (base, purple, teal, orange).
 */
fun chartTint(index: Int, base: Color, semantic: MetricSemantic?, dark: Boolean): Color {
    val palette = chartPalette(dark)
    semantic?.signal?.let { return signalColor(it, base, dark) }
    flowColor(semantic?.flow, dark)?.let { return it }
    return when (index) {
        0 -> base
        1 -> palette.PURPLE
        2 -> palette.TEAL
        3 -> palette.ORANGE
        else -> palette.SECONDARY
    }
}

/**
 * Mirrors ChartSeriesPalette.seriesTints: semantic preference first
 * (signal, else flow), then rotation through blue/purple/teal/orange with
 * dedup so stacked segments stay distinguishable.
 */
fun seriesTints(semantics: List<MetricSemantic?>, dark: Boolean): List<Color> {
    val palette = chartPalette(dark)
    val defaults = listOf(
        palette.BLUE,
        palette.PURPLE,
        palette.TEAL,
        palette.ORANGE,
    )
    val used = mutableSetOf<Color>()
    return semantics.mapIndexed { index, semantic ->
        val preferred: Color? = semantic?.signal?.let { signalColor(it, palette.SECONDARY, dark) }
            .takeIf { semantic?.signal != null }
            ?: flowColor(semantic?.flow, dark)
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
fun activityTint(kind: String, signal: String?, accent: Color, dark: Boolean): Color {
    val palette = chartPalette(dark)
    signal?.let { return signalColor(it, accent, dark) }
    return when (kind) {
        "charging" -> palette.GREEN
        "appliance", "progress" -> palette.BLUE
        "job", "timer" -> palette.ORANGE
        else -> accent
    }
}
