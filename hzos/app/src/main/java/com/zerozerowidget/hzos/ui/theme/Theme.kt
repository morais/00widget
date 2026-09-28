package com.zerozerowidget.hzos.ui.theme

import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import com.zerozerowidget.hzos.ui.uiset.UiSetAccent
import metavrx.uiset.compose.theme.ContentColors
import metavrx.uiset.compose.theme.LocalColorScheme
import metavrx.uiset.compose.theme.Spacing
import metavrx.uiset.compose.theme.UiSetIndicationDefaults
import metavrx.uiset.compose.theme.UiSetTheme
import metavrx.uiset.compose.theme.darkColorScheme as uiSetDarkColorScheme
import metavrx.uiset.compose.theme.lightColorScheme as uiSetLightColorScheme
import metavrx.uiset.compose.theme.withAccent

/**
 * UI Set is the whole theme: its dark or light scheme following the
 * system, its type scale, shapes and dimensions, with the iOS-blue accent
 * carried over so the brand (and the chart fallback tint) survives. There
 * is no Material colour scheme underneath any more; every card, control
 * and text colour reads UI Set.
 *
 * UiSet refuses an accent neither of its content candidates reaches 4.5:1
 * on, so the content colors are explicit: white on iOS blue is this app's
 * long-standing button look, kept deliberately rather than re-derived.
 * Type, shapes, and dimensions come from the library defaults via the
 * ambient theme: the outer layer provides them, the inner one keeps them
 * while swapping in the accented scheme.
 */
@Composable
fun ZeroZeroWidgetTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val scheme = remember(dark) {
        (if (dark) uiSetDarkColorScheme() else uiSetLightColorScheme()).withAccent(
            UiSetAccent,
            ContentColors(
                primary = Color.White,
                secondary = Color.White,
                icon = Color.White
            )
        )
    }
    UiSetTheme {
        UiSetTheme(
            colorScheme = scheme,
            typography = UiSetTheme.typography,
            shapes = UiSetTheme.shapes,
            dimensions = UiSetTheme.dimensions,
            indications = UiSetIndicationDefaults.rememberConfig(scheme)
        ) {
            content()
        }
    }
}

/**
 * Window-filling background for panel roots, applied before content
 * padding so it paints edge to edge. Dark stays fully transparent
 * (passthrough shows through); light paints the scheme surface as
 * glass — mostly opaque for readability, translucent enough that the
 * room behind still reads. There is no toggle and no system signal
 * for passthrough-vs-immersive, so one static behavior has to serve
 * both: glass degrades gracefully where a void would show black and
 * stays calm over a bright room. Reads the theme, so it tracks
 * dark/light switches. Tune [LIGHT_GLASS_ALPHA] on device.
 */
private const val LIGHT_GLASS_ALPHA = 0.8f

@Composable
fun Modifier.panelBackground(): Modifier = if (isSystemInDarkTheme()) {
    this
} else {
    // UI Set's panel colour: the darker stop of its light background
    // gradient, so the white cards (GlassPrimaryCard) stand off it.
    val panel = LocalColorScheme.current.background.container.colors.asList()
    background(panel.minBy { it.luminance() }.copy(alpha = LIGHT_GLASS_ALPHA))
}

/**
 * UI Set's spacing scale (4, 8, 12, 16, 24, 32 dp), read from the theme so
 * a platform density change reaches every panel at once. Paddings, gaps
 * and spacers use these; component sizes (chart heights, icon boxes) do
 * not, since those are geometry rather than rhythm.
 */
val spacing: Spacing
    @Composable
    @ReadOnlyComposable
    get() = UiSetTheme.dimensions.spacing
