package com.zerozerowidget.hzos.ui.uiset

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.input.KeyboardType
import metavrx.uiset.compose.button.ButtonStyle
import metavrx.uiset.compose.button.LabelButton
import metavrx.uiset.compose.control.Switch
import metavrx.uiset.compose.dialog.BasicDialog
import metavrx.uiset.compose.dialog.DialogAction
import metavrx.uiset.compose.input.TextField
import metavrx.uiset.compose.slider.Slider

/**
 * Thin aliases over Meta UI Set controls, so call sites stay short and
 * the style mapping lives in one place: M3 Button → Primary, M3
 * FilledTonalButton → Secondary, destructive confirms → Destructive.
 * Switch, Slider, text fields, and confirm dialogs map one to one.
 *
 * None of these opens its own UiSetTheme. ZeroZeroWidgetTheme provides
 * the accented UiSet scheme at every panel root, so a wrapper-level theme
 * only added provider layers per control — and a parameterless one could
 * only ever restate or undercut the root's accent.
 */
@Composable
fun UiSetPrimaryButton(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    LabelButton(
        label = label,
        onClick = onClick,
        modifier = modifier,
        style = ButtonStyle.Primary,
        enabled = enabled,
    )
}

@Composable
fun UiSetSecondaryButton(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    LabelButton(
        label = label,
        onClick = onClick,
        modifier = modifier,
        style = ButtonStyle.Secondary,
        enabled = enabled,
    )
}

@Composable
fun UiSetDestructiveButton(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    LabelButton(
        label = label,
        onClick = onClick,
        modifier = modifier,
        style = ButtonStyle.Destructive,
        enabled = enabled,
    )
}

@Composable
fun UiSetIconButton(
    onClick: () -> Unit,
    contentDescription: String,
    modifier: Modifier = Modifier,
    style: ButtonStyle = ButtonStyle.Borderless,
    content: @Composable () -> Unit,
) {
    metavrx.uiset.compose.button.IconButton(
        icon = content,
        onClick = onClick,
        contentDescription = contentDescription,
        modifier = modifier,
        style = style,
    )
}

@Composable
fun UiSetSwitch(
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
    contentDescription: String? = null,
) {
    Switch(
        checked = checked,
        onCheckedChange = onCheckedChange,
        modifier = modifier,
        contentDescription = contentDescription,
    )
}

@Composable
fun UiSetSlider(
    value: Float,
    onValueChange: (Float) -> Unit,
    valueRange: ClosedFloatingPointRange<Float>,
    modifier: Modifier = Modifier,
    onValueChangeFinished: (() -> Unit)? = null,
) {
    Slider(
        value = value,
        onValueChange = onValueChange,
        modifier = modifier,
        valueRange = valueRange,
        onValueChangeFinished = onValueChangeFinished,
    )
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

/**
 * Single-line text entry. UiSet's field takes [keyboardType] directly
 * instead of Material's [KeyboardOptions] wrapper, and has no read-only
 * mode — callers with a locked value pass enabled = false, which reads
 * disabled rather than read-only.
 */
@Composable
fun UiSetTextField(
    value: String,
    label: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    singleLine: Boolean = true,
    keyboardType: KeyboardType = KeyboardType.Text,
    placeholder: String? = null,
    supportingText: String? = null,
) {
    TextField(
        value = value,
        label = label,
        onValueChange = onValueChange,
        modifier = modifier,
        placeholder = placeholder,
        supportingText = supportingText,
        enabled = enabled,
        singleLine = singleLine,
        keyboardType = keyboardType,
    )
}

/**
 * The accent swatch as a text color. This is the same iOS blue the root
 * theme accents the UiSet scheme with (see ZeroZeroWidgetTheme) — read
 * from a const rather than the scheme because UiSet keeps its accent
 * container brush internal. For accent-colored text on surfaces — the old
 * `primary` text role.
 */
/** The iOS blue the root theme accents the UiSet scheme with. */
internal val UiSetAccent = Color(0xFF0A84FF)

fun uiSetAccent(): Color = UiSetAccent
