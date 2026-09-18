package com.example.zerozerowidget.hzos.ui.theme

import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.graphics.Color

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
            content()
        }
    }
}
