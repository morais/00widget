package com.zerozerowidget.hzos.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ApplicationProvider
import com.github.takahirom.roborazzi.captureRoboImage
import com.zerozerowidget.hzos.ZeroZeroWidgetApp
import com.zerozerowidget.hzos.data.SampleData
import com.zerozerowidget.hzos.ui.dashboard.CardDetailPanel
import com.zerozerowidget.hzos.ui.dashboard.DashboardPanel
import com.zerozerowidget.hzos.ui.settings.LocalBuildStamp
import com.zerozerowidget.hzos.ui.settings.SettingsPanel
import com.zerozerowidget.hzos.ui.theme.ZeroZeroWidgetTheme
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.ParameterizedRobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Renders the real panels, with the on-device sample deck, at every width
 * in [PanelBreakpoints.TestedWidthsDp]: the 320dp shell floor, the Glasses
 * minimum, and each side of every breakpoint.
 *
 * Each panel is drawn into a fixed box of exactly that width, which is what
 * a shell window hands it, so BoxWithConstraints sees the same number it
 * will on a headset. Clipping at a narrow width — the bug that started this
 * — shows up as content cut at the box's right edge.
 *
 * `./gradlew recordRoborazziDebug` writes the PNGs to src/test/screenshots;
 * `verifyRoborazziDebug` fails when a layout changes; a plain unit test run
 * only renders. Proves layout only: Look and Pinch, shell resizing and
 * passthrough are outside it.
 */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [34], qualifiers = "w1400dp-h1000dp-xhdpi")
class PanelLayoutScreenshotTest(private val widthDp: Int) {
    companion object {
        @JvmStatic
        @ParameterizedRobolectricTestRunner.Parameters(name = "{0}dp")
        fun widths() = PanelBreakpoints.TestedWidthsDp.map { arrayOf<Any>(it) }

        private const val HEIGHT_DP = 800
    }

    @get:Rule
    val compose = createComposeRule()

    private val app: ZeroZeroWidgetApp get() = ApplicationProvider.getApplicationContext()

    private fun withSamples() {
        // SampleStore loads from disk on a background thread after it is
        // built, and a generate that lands first is overwritten by that
        // (empty) load — audit C6. Regenerate until the deck sticks.
        compose.waitUntil(timeoutMillis = 5_000) {
            if (app.sampleStore.cards.value.isEmpty()) app.sampleStore.generateCards()
            app.sampleStore.cards.value.isNotEmpty()
        }
    }

    private fun capture(name: String, content: @Composable () -> Unit) {
        compose.setContent {
            ZeroZeroWidgetTheme {
                Box(Modifier.requiredSize(widthDp.dp, HEIGHT_DP.dp).testTag("panel")) {
                    content()
                }
            }
        }
        compose.waitForIdle()
        compose.onNodeWithTag("panel")
            .captureRoboImage("src/test/screenshots/${name}_${widthDp}dp.png")
    }

    @Test
    fun dashboard() {
        withSamples()
        capture("dashboard") {
            DashboardPanel(app = app, onOpenSettings = {}, onPopOut = { _, _ -> }, onPopOutActivity = { _, _ -> })
        }
    }

    @Test
    fun cardDetail() {
        withSamples()
        // The first sample card carries actions, a link and a chart: the
        // row whose buttons clipped at the narrowest width.
        val card = SampleData.makeCards().first { !it.actions.isNullOrEmpty() }
        capture("card-detail") {
            CardDetailPanel(app = app, cardId = card.id, isSample = true, onOpenLink = {}, onDeleted = {})
        }
    }

    @Test
    fun settings() {
        capture("settings") {
            // The real stamp changes with every commit and hour.
            CompositionLocalProvider(LocalBuildStamp provides "Version test") {
                SettingsPanel(app = app, onClose = {}, onSendAuthUrl = { _, _ -> })
            }
        }
    }
}
