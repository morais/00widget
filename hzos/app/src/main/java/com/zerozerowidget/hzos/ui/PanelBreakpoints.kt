package com.zerozerowidget.hzos.ui

import androidx.compose.ui.unit.dp

/**
 * Every width a panel changes layout at, in one place, so the screenshot
 * test (PanelLayoutScreenshotTest) and the layouts agree on them. Panels
 * run from the 320dp shell floor to 1280dp; Meta VR Glasses support
 * 360-1280dp.
 */
object PanelBreakpoints {
    /** Dashboard shows two card columns from here up (mirrors iOS). */
    val DashboardTwoColumns = 728.dp

    /** Card detail keeps actions, link and delete on one row from here up. */
    val DetailInlineActions = 400.dp

    /** Settings shows its destinations as a side rail from here up. */
    val SettingsRail = 600.dp

    /** The widths the screenshot test renders every panel at. */
    val TestedWidthsDp = listOf(320, 360, 400, 728, 1280)
}
