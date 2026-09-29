package com.zerozerowidget.hzos.ui.cards

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.zerozerowidget.hzos.data.ActionDefinition
import com.zerozerowidget.hzos.data.DashboardCard
import com.zerozerowidget.hzos.data.DashboardStatus
import com.zerozerowidget.hzos.ui.LocalHideSampleIndicators
import com.zerozerowidget.hzos.ui.theme.spacing
import com.zerozerowidget.hzos.ui.uiset.UiSetConfirmDialog
import com.zerozerowidget.hzos.ui.uiset.UiSetDestructiveButton
import com.zerozerowidget.hzos.ui.uiset.UiSetIconButton
import com.zerozerowidget.hzos.ui.uiset.UiSetPrimaryButton
import com.zerozerowidget.hzos.ui.uiset.UiSetSecondaryButton
import com.zerozerowidget.hzos.ui.uiset.uiSetAccent
import metavrx.uiset.compose.Icon
import metavrx.uiset.compose.Text
import metavrx.uiset.compose.theme.LocalColorScheme
import metavrx.uiset.compose.theme.LocalContentColors
import metavrx.uiset.compose.theme.LocalTypography
import metavrx.uiset.compose.theme.icons.Icons

@Composable
fun StatusDot(status: DashboardStatus, modifier: Modifier = Modifier) {
    val dark = isSystemInDarkTheme()
    val unknown = LocalContentColors.current.secondary
    // Colour alone says nothing to a screen reader or to Look and Pinch's
    // UI understanding, so the dot names its status (readiness #20).
    Canvas(modifier = modifier.size(10.dp).semantics { contentDescription = "Status: ${status.raw}" }) {
        drawCircle(statusColor(status, unknown, dark))
    }
}

/**
 * Determinate progress bar. UiSet ships progress *colors* but no bar
 * component, and every use here is a known fraction — so a rounded
 * track plus a rounded fill, no animation, nothing to configure. The
 * colours are UI Set's progress indicator and track, which also hold up
 * in light mode, where an accent at a fixed alpha did not.
 */
@Composable
fun ProgressBar(
    fraction: Float,
    modifier: Modifier = Modifier,
    color: Color = LocalColorScheme.current.progress.indicator,
    trackColor: Color = LocalColorScheme.current.progress.track,
    height: Dp = 4.dp
) {
    Canvas(modifier.fillMaxWidth().height(height)) {
        val radius = size.height / 2
        drawRoundRect(
            color = trackColor,
            cornerRadius = CornerRadius(radius, radius)
        )
        val width = size.width * fraction.coerceIn(0f, 1f)
        if (width > 0f) {
            drawRoundRect(
                color = color,
                topLeft = Offset.Zero,
                size = Size(width, size.height),
                cornerRadius = CornerRadius(radius, radius)
            )
        }
    }
}

/**
 * Demo-data pill. Solid primary lozenge, white text, fixed padding — an
 * inline element that can sit anywhere a label sits, so it never disturbs
 * the surrounding layout (no rotation, no overflow, no offsets).
 */
@Composable
fun SampleBadge(modifier: Modifier = Modifier) {
    // Gated centrally so every pill obeys hide-sample-indicators together.
    if (LocalHideSampleIndicators.current) return
    Box(
        modifier = modifier
            .background(
                uiSetAccent(),
                RoundedCornerShape(4.dp)
            )
            .padding(horizontal = spacing.small, vertical = 2.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(
            "SAMPLE",
            style = LocalTypography.current.caption,
            color = Color.White
        )
    }
}

/**
 * Demo-data banner. Same pill pattern at full width: primary background,
 * white text, iOS wording verbatim ("These are samples" + the generated-
 * on-device sentence + "Remove sample widgets"). Answers the user's
 * question directly: no, "This is sample data" was ours — this is iOS's.
 */
@Composable
fun SampleNoticeBanner(onRemoveAll: () -> Unit, modifier: Modifier = Modifier) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .background(
                uiSetAccent(),
                RoundedCornerShape(8.dp)
            )
            .padding(horizontal = spacing.medium, vertical = spacing.medium),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(spacing.medium)
    ) {
        Column(Modifier.weight(1f)) {
            Text(
                "These are samples",
                style = LocalTypography.current.title,
                color = Color.White
            )
            Text(
                "These samples were generated on this device to show what 00Widget looks like. No agent published them.",
                style = LocalTypography.current.bodySmall,
                color = Color.White
            )
        }
        UiSetSecondaryButton(
            label = "Remove samples",
            onClick = onRemoveAll
        )
    }
}

/**
 * Pop-out affordance: UI Set's open-in-new glyph (box with an arrow
 * leaving top-right). These were Canvas strokes while the only glyph
 * source was the headset font, which lacked the symbols; UI Set's icon
 * set is vector and always present.
 */
@Composable
fun PopOutIconButton(onPopOut: () -> Unit, modifier: Modifier = Modifier) {
    UiSetIconButton(onClick = onPopOut, contentDescription = "Pop out", modifier = modifier) {
        Icon(
            Icons.Regular.OpenTab,
            contentDescription = null,
            tint = LocalContentColors.current.secondary
        )
    }
}

/**
 * Link affordance: a globe, since the link opens in the headset browser.
 * Sits left of the pop-out icon wherever both appear, so the corner reads
 * link-then-pop-out.
 */
@Composable
fun LinkIconButton(onOpenLink: () -> Unit, modifier: Modifier = Modifier) {
    UiSetIconButton(onClick = onOpenLink, contentDescription = "Open link", modifier = modifier) {
        Icon(
            Icons.Regular.World,
            contentDescription = null,
            tint = LocalContentColors.current.secondary
        )
    }
}

/** Safe action button with in-flight + error state. Unsafe actions render as a note, never a button. */
@Composable
fun ActionButtons(
    card: DashboardCard,
    onRun: (ActionDefinition) -> Unit,
    runningId: String?,
    runError: String?,
    modifier: Modifier = Modifier
) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(spacing.xSmall)) {
        card.actions.orEmpty().forEach { action ->
            if (action.isSafeFromPanel) {
                UiSetPrimaryButton(
                    label = if (runningId == action.id) "Running…" else action.label,
                    onClick = { onRun(action) },
                    enabled = runningId == null,
                    modifier = Modifier.fillMaxWidth()
                )
            } else {
                UiSetSecondaryButton(
                    label = "${action.label} — confirm in app",
                    onClick = {},
                    enabled = false,
                    modifier = Modifier.fillMaxWidth()
                )
            }
        }
        runError?.let {
            Text(
                it,
                style = LocalTypography.current.bodySmall,
                color = LocalColorScheme.current.negative.content
            )
        }
    }
}

/**
 * Delete affordance shared by card and activity detail panels. Samples read
 * "Remove sample" — unless indicators are hidden, in which case the card
 * plays real down to the Delete label. Either way removal itself stays
 * local for samples (the caller routes it); only the label changes, so a
 * hidden-indicators deck is never left with an unremovable card.
 */
@Composable
fun SampleAwareDeleteRow(
    isSample: Boolean,
    serverLabel: String,
    busy: Boolean,
    error: String?,
    onDelete: () -> Unit,
    confirmTitle: String,
    confirmText: String,
    modifier: Modifier = Modifier,
    leading: @Composable RowScope.() -> Unit = {},
    fillLeading: Boolean = false
) {
    DeleteRow(
        label = if (isSample && !LocalHideSampleIndicators.current) {
            "Remove sample"
        } else {
            serverLabel
        },
        busy = busy,
        error = error,
        onDelete = onDelete,
        confirmTitle = confirmTitle,
        confirmText = confirmText,
        modifier = modifier,
        leading = leading,
        fillLeading = fillLeading
    )
}

/**
 * Destructive action behind a UI Set confirm dialog. Compact and
 * right-aligned: a small destructive button, never a full-width banner.
 *
 * This used to be a two-tap arm ("Sure?") on the button itself. Armed
 * never expired, and under Look and Pinch a second pinch at the same gaze
 * point is the easiest gesture there is — an accidental double pinch
 * deleted. A dialog moves the confirm somewhere else and names the thing.
 */
@Composable
fun DeleteRow(
    label: String,
    busy: Boolean,
    error: String?,
    onDelete: () -> Unit,
    confirmTitle: String,
    confirmText: String,
    modifier: Modifier = Modifier,
    leading: @Composable RowScope.() -> Unit = {},
    /**
     * True when [leading] already distributes the row width (e.g. action
     * buttons on a weight): the spacer that would otherwise push the
     * button right is skipped, so everything shares one line.
     */
    fillLeading: Boolean = false
) {
    var confirming by remember { mutableStateOf(false) }
    // The caller owns the width: details stretch full width with the
    // button right-aligned, list rows wrap the button. A fixed width
    // here wrapped "Disconnect" onto two lines at larger type.
    Column(modifier) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            leading()
            if (!fillLeading) Spacer(Modifier.weight(1f))
            DeleteButton(label = label, busy = busy, onClick = { confirming = true })
        }
        error?.let {
            Spacer(Modifier.height(spacing.xSmall))
            Text(
                it,
                style = LocalTypography.current.bodySmall,
                color = LocalColorScheme.current.negative.content
            )
        }
    }
    if (confirming) {
        DeleteConfirmDialog(
            title = confirmTitle,
            text = confirmText,
            confirmLabel = label,
            onConfirm = {
                confirming = false
                onDelete()
            },
            onDismiss = { confirming = false }
        )
    }
}

/**
 * The one destructive confirm: every delete, remove, end and disconnect
 * asks through this, so they read and behave alike. Cancel is the safe
 * default; the confirm button carries the action's own label.
 */
@Composable
fun DeleteConfirmDialog(
    title: String,
    text: String,
    confirmLabel: String,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit
) {
    UiSetConfirmDialog(
        title = title,
        text = text,
        confirmLabel = confirmLabel,
        onConfirm = onConfirm,
        dismissLabel = "Cancel",
        onDismiss = onDismiss,
        destructive = true
    )
}

/**
 * The destructive button alone, for rows composed explicitly — action
 * buttons on a weight, then link, then this. It only asks: the caller
 * owns the confirm dialog, as [DeleteRow] does.
 */
@Composable
fun DeleteButton(label: String, busy: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier) {
    UiSetDestructiveButton(
        label = if (busy) "Working…" else label,
        onClick = onClick,
        enabled = !busy,
        modifier = modifier
    )
}

/**
 * "Needs you" pill, drawn — never a button. Look and Pinch highlights
 * every clickable element, so a badge built from a button would light up
 * as a target that does nothing. Mirrors the derived rule in llms.md
 * (attention status + actionable button); callers decide, this only
 * draws. No callers yet — kept so the first one starts here.
 */
@Composable
fun NeedsYouBadge(modifier: Modifier = Modifier) {
    val colors = LocalColorScheme.current.notification
    Box(
        modifier = modifier
            .background(colors.container, RoundedCornerShape(4.dp))
            .padding(horizontal = spacing.small, vertical = 2.dp),
        contentAlignment = Alignment.Center
    ) {
        Text("Needs you", style = LocalTypography.current.caption, color = colors.onContainer)
    }
}
