package com.example.zerozerowidget.hzos.ui.uiset

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import metavrx.uiset.compose.button.ButtonStyle
import metavrx.uiset.compose.button.LabelButton
import metavrx.uiset.compose.control.Switch
import metavrx.uiset.compose.dialog.BasicDialog
import metavrx.uiset.compose.dialog.DialogAction
import metavrx.uiset.compose.slider.Slider
import metavrx.uiset.compose.theme.UiSetTheme

/**
 * Meta UI Set controls for the Settings pilot, one thin wrapper each.
 *
 * Each wrapper applies [UiSetTheme] to its own subtree only. That is
 * deliberate containment, not layering taste: UiSetTheme owns colors,
 * type, shapes, and interaction feedback for everything under it, and
 * wrapping whole screens would restyle the Material 3 text and surfaces
 * around these controls. When a full screen migrates, the theme moves up
 * to that screen root and these wrappers go away.
 *
 * Mappings: M3 Button → Primary, M3 FilledTonalButton → Secondary,
 * destructive confirms → Destructive. Switch, Slider, and confirm dialogs
 * map one to one. Everything else (text, fields, cards, badges) stays
 * Material 3 until its own migration.
 */
@Composable
fun UiSetPrimaryButton(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    UiSetTheme {
        LabelButton(
            label = label,
            onClick = onClick,
            modifier = modifier,
            style = ButtonStyle.Primary,
            enabled = enabled,
        )
    }
}

@Composable
fun UiSetSecondaryButton(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    UiSetTheme {
        LabelButton(
            label = label,
            onClick = onClick,
            modifier = modifier,
            style = ButtonStyle.Secondary,
            enabled = enabled,
        )
    }
}

@Composable
fun UiSetDestructiveButton(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    UiSetTheme {
        LabelButton(
            label = label,
            onClick = onClick,
            modifier = modifier,
            style = ButtonStyle.Destructive,
            enabled = enabled,
        )
    }
}

@Composable
fun UiSetIconButton(
    onClick: () -> Unit,
    contentDescription: String,
    modifier: Modifier = Modifier,
    style: ButtonStyle = ButtonStyle.Borderless,
    content: @Composable () -> Unit,
) {
    UiSetTheme {
        metavrx.uiset.compose.button.IconButton(
            icon = content,
            onClick = onClick,
            contentDescription = contentDescription,
            modifier = modifier,
            style = style,
        )
    }
}

@Composable
fun UiSetSwitch(
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
    contentDescription: String? = null,
) {
    UiSetTheme {
        Switch(
            checked = checked,
            onCheckedChange = onCheckedChange,
            modifier = modifier,
            contentDescription = contentDescription,
        )
    }
}

@Composable
fun UiSetSlider(
    value: Float,
    onValueChange: (Float) -> Unit,
    valueRange: ClosedFloatingPointRange<Float>,
    modifier: Modifier = Modifier,
    onValueChangeFinished: (() -> Unit)? = null,
) {
    UiSetTheme {
        Slider(
            value = value,
            onValueChange = onValueChange,
            modifier = modifier,
            valueRange = valueRange,
            onValueChangeFinished = onValueChangeFinished,
        )
    }
}

/**
 * One confirm/cancel question. [destructive] paints the confirm action
 * destructive; everything else reads Secondary.
 */
@Composable
fun UiSetConfirmDialog(
    title: String,
    text: String,
    confirmLabel: String,
    onConfirm: () -> Unit,
    dismissLabel: String,
    onDismiss: () -> Unit,
    destructive: Boolean = false,
    confirmEnabled: Boolean = true,
) {
    UiSetTheme {
        BasicDialog(
            title = title,
            description = text,
            primaryAction = DialogAction(
                label = confirmLabel,
                onClick = onConfirm,
                enabled = confirmEnabled,
                destructive = destructive,
            ),
            onDismissRequest = onDismiss,
            secondaryAction = DialogAction(
                label = dismissLabel,
                onClick = onDismiss,
            ),
        )
    }
}
