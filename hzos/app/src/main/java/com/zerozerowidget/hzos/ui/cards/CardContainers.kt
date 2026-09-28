package com.zerozerowidget.hzos.ui.cards

import com.zerozerowidget.hzos.ui.theme.spacing
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import metavrx.uiset.compose.card.PrimaryCard
import metavrx.uiset.compose.card.CardDefaults as UiSetCardDefaults
import metavrx.uiset.compose.theme.BrushSpec
import metavrx.uiset.compose.theme.UiSetTheme
import metavrx.uiset.compose.theme.LocalColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.unit.dp
import com.zerozerowidget.hzos.data.DashboardCard

/**
 * The one card container. UI Set's PrimaryCard — its shape, padding,
 * content colours, and (when [onClick] is set) its press and hover
 * feedback — with the container made translucent by [cardAlpha] so the
 * room still shows through. UI Set's CardColors take a BrushSpec, so the
 * glass is a BrushSpec.Solid of UI Set's panel colour at that alpha.
 *
 * Non-null [onClick] makes the whole card one target; leave it null for
 * cards that only hold content, so Look and Pinch does not highlight
 * something that does nothing.
 */
@Composable
fun GlassPrimaryCard(
    cardAlpha: Float,
    modifier: Modifier = Modifier,
    onClick: (() -> Unit)? = null,
    contentPadding: androidx.compose.ui.unit.Dp = 16.dp,
    content: @Composable androidx.compose.foundation.layout.ColumnScope.() -> Unit,
) {
    // UI Set's own card fill is a faint tint (white at 10% in dark, black
    // at 9% in light) made to sit on UI Set's opaque panel background.
    // Over passthrough there is no such background, so the card borrows
    // the panel colour itself — the darker stop of its gradient in dark,
    // the lighter in light — and cardAlpha decides how much room shows.
    val dark = androidx.compose.foundation.isSystemInDarkTheme()
    val panel = LocalColorScheme.current.background.container.colors.asList()
    val fill = if (dark) panel.minBy { it.luminance() } else panel.maxBy { it.luminance() }
    val colors = UiSetCardDefaults.Primary.copy(
        container = BrushSpec.Solid(fill.copy(alpha = cardAlpha)),
    )
    PrimaryCard(
        modifier = modifier.fillMaxWidth(),
        onClick = onClick,
        colors = colors,
        // No elevation: a shadow is drawn beneath the card, and through a
        // translucent fill it shows as a second, darker box inside it.
        dimensions = UiSetTheme.dimensions.cards.copy(
            contentPadding = contentPadding,
            primaryElevation = 0.dp,
        ),
        content = content,
    )
}

/**
 * Shared glass container for non-card content (settings bodies, detail
 * wrappers) that should read as the same object family as the cards.
 */
@Composable
fun GlassCard(
    cardAlpha: Float,
    modifier: Modifier = Modifier,
    content: @Composable androidx.compose.foundation.layout.ColumnScope.() -> Unit,
) {
    GlassPrimaryCard(cardAlpha = cardAlpha, modifier = modifier, content = content)
}

@Composable
fun DetailCard(card: DashboardCard, cardAlpha: Float, isSample: Boolean, interactiveCharts: Boolean = false) {
    // Overlay badge, not layout — see DashboardRow.
    Box(Modifier.fillMaxWidth()) {
    GlassPrimaryCard(cardAlpha = cardAlpha) {
        CardHeadline(card)
        Spacer(Modifier.height(spacing.small))
        CardTemplateBody(card, interactiveCharts = interactiveCharts)
    }
        if (isSample) {
            SampleBadge(
                Modifier
                    .align(Alignment.BottomEnd)
                    .padding(spacing.small),
            )
        }
    }
}
