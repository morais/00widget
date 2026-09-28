package com.zerozerowidget.hzos.ui.theme

import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import com.zerozerowidget.hzos.ZeroZeroWidgetApp
import com.zerozerowidget.hzos.ui.uiset.UiSetAccent
import metavrx.uiset.compose.theme.ContentColors
import metavrx.uiset.compose.theme.UiSetIndicationDefaults
import metavrx.uiset.compose.theme.UiSetTheme
import metavrx.uiset.compose.theme.darkColorScheme as uiSetDarkColorScheme
import metavrx.uiset.compose.theme.lightColorScheme as uiSetLightColorScheme
import metavrx.uiset.compose.theme.withAccent

private val Scheme = darkColorScheme(
    // iOS system blue with white text: buttons and links read correctly on
    // dark surfaces (a light primary with dark text was unreadable), and it
    // doubles as the chart fallback tint where iOS uses .accentColor.
    primary = Color(0xFF0A84FF),
    onPrimary = Color(0xFFFFFFFF),
    secondary = Color(0xFFA5B4FC),
    surface = Color(0xFF14181D),
    onSurface = Color(0xFFE8EAED),
    surfaceVariant = Color(0xFF1E242B),
    onSurfaceVariant = Color(0xFFB9C2CC),
    outline = Color(0xFF3A434E),
    error = Color(0xFFF87171),
)

/** iOS light-mode mirror of [Scheme]: grey cards on grouped background. */
private val LightScheme = lightColorScheme(
    primary = Color(0xFF007AFF),
    onPrimary = Color(0xFFFFFFFF),
    secondary = Color(0xFF5E5CE6),
    surface = Color(0xFFF2F2F7),
    onSurface = Color(0xFF1C1C1E),
    // Deliberately grey, not white: without elevation shadows a white
    // card on a near-white surface is invisible.
    surfaceVariant = Color(0xFFE9E9EE),
    onSurfaceVariant = Color(0xFF636366),
    outline = Color(0xFFD1D1D6),
    error = Color(0xFFFF3B30),
)

/**
 * Panels follow the system theme on both layers. In practice Horizon OS
 * reports dark, so the light path is dormant-correct rather than
 * device-verified: same structure, mirrored values, charts included.
 */
@Composable
fun ZeroZeroWidgetTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val materialScheme = if (dark) Scheme else LightScheme
    MaterialTheme(colorScheme = materialScheme) {
        // Bare-column text (headers, labels outside cards) has no Surface to
        // derive a content color from and would fall back to ambient black.
        CompositionLocalProvider(LocalContentColor provides materialScheme.onSurface) {
            // Full UiSet adoption for text and controls: the platform dark
            // scheme and type scale, with the iOS-blue accent carried over
            // so the brand (and the chart fallback tint) survives the move.
            // Material stays underneath for what UiSet cannot express —
            // alpha-translucent card containers, linear progress — which
            // keep reading this scheme. Type, shapes, and dimensions come
            // from the library defaults via the ambient theme: the outer
            // layer provides them, the inner one keeps them while swapping
            // in the accented scheme.
            //
            // UiSet refuses an accent neither of its content candidates
            // reaches 4.5:1 on, so the content colors are explicit: white
            // on iOS blue is this app's long-standing button look, kept
            // deliberately rather than re-derived.
            val scheme = remember(dark) {
                (if (dark) uiSetDarkColorScheme() else uiSetLightColorScheme()).withAccent(
                    UiSetAccent,
                    ContentColors(
                        primary = Color.White,
                        secondary = Color.White,
                        icon = Color.White,
                    ),
                )
            }
            UiSetTheme {
                UiSetTheme(
                    colorScheme = scheme,
                    typography = UiSetTheme.typography,
                    shapes = UiSetTheme.shapes,
                    dimensions = UiSetTheme.dimensions,
                    indications = UiSetIndicationDefaults.rememberConfig(scheme),
                ) {
                    content()
                }
            }
        }
    }
}

/**
 * Window-filling background for panel roots, applied before content
 * padding so it paints edge to edge. Transparent follows the toggle
 * into passthrough; opaque paints the scheme surface — never the
 * window's black drawable, which is invisible in dark mode and glaring
 * in light mode. Reads the theme, so it tracks dark/light switches.
 * Unset means follow the theme (transparent when dark, surfaces when
 * light); an explicit toggle choice always wins.
 */
@Composable
fun Modifier.panelBackground(app: ZeroZeroWidgetApp): Modifier {
    val override by app.panelPrefs.transparentOverride.collectAsState(initial = null)
    val transparent = override ?: androidx.compose.foundation.isSystemInDarkTheme()
    return if (transparent) {
        this
    } else {
        background(MaterialTheme.colorScheme.surface)
    }
}
