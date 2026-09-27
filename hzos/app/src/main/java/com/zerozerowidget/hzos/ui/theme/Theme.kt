package com.zerozerowidget.hzos.ui.theme

import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.ui.graphics.Color
import com.zerozerowidget.hzos.ui.uiset.UiSetAccent
import metavrx.uiset.compose.theme.ContentColors
import metavrx.uiset.compose.theme.UiSetIndicationDefaults
import metavrx.uiset.compose.theme.UiSetTheme
import metavrx.uiset.compose.theme.darkColorScheme as uiSetDarkColorScheme
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

/** Dark theme for every panel. Panels float in passthrough, so surfaces stay dark. */
@Composable
fun ZeroZeroWidgetTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = Scheme) {
        // Bare-column text (headers, labels outside cards) has no Surface to
        // derive a content color from and would fall back to ambient black.
        CompositionLocalProvider(LocalContentColor provides Scheme.onSurface) {
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
            val scheme = remember {
                uiSetDarkColorScheme().withAccent(
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
