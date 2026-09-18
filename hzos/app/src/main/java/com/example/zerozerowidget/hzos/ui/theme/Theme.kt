package com.example.zerozerowidget.hzos.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

private val Scheme = darkColorScheme(
    primary = Color(0xFF7DD3FC),
    onPrimary = Color(0xFF06202E),
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
    MaterialTheme(colorScheme = Scheme, content = content)
}
