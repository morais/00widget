package com.zerozerowidget.hzos.ui.uiset

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.input.KeyboardType
import com.zerozerowidget.hzos.R
import metavrx.uiset.compose.Icon
import metavrx.uiset.compose.button.ButtonStyle
import metavrx.uiset.compose.button.IconButton
import metavrx.uiset.compose.button.LabelButton
import metavrx.uiset.compose.control.Switch
import metavrx.uiset.compose.dialog.BasicDialog
import metavrx.uiset.compose.dialog.DialogAction
import metavrx.uiset.compose.input.TextField
import metavrx.uiset.compose.slider.Slider
import metavrx.uiset.compose.theme.icons.Icons

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
    enabled: Boolean = true
) {
    LabelButton(
        label = label,
        onClick = onClick,
        modifier = modifier,
        style = ButtonStyle.Primary,
        enabled = enabled
    )
}

@Composable
fun UiSetSecondaryButton(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true
) {
    // UI Set's dark Secondary fill is white at 10%, a tint made for its own
    // opaque panel background. On a translucent card over passthrough it
    // picks up the room and nearly vanishes, so in dark it is an opaque
    // grey instead: separate from the #272727 card, white text at ~7:1.
    val style = if (isSystemInDarkTheme()) {
        ButtonStyle.Secondary.copy(containerColor = DARK_SECONDARY_CONTAINER)
    } else {
        ButtonStyle.Secondary
    }
    LabelButton(
        label = label,
        onClick = onClick,
        modifier = modifier,
        style = style,
        enabled = enabled
    )
}

private val DARK_SECONDARY_CONTAINER = Color(0xFF5A5A5A)

@Composable
fun UiSetDestructiveButton(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true
) {
    LabelButton(
        label = label,
        onClick = onClick,
        modifier = modifier,
        style = ButtonStyle.Destructive,
        enabled = enabled
    )
}

@Composable
fun UiSetIconButton(
    onClick: () -> Unit,
    contentDescription: String,
    modifier: Modifier = Modifier,
    style: ButtonStyle = ButtonStyle.Borderless,
    enabled: Boolean = true,
    content: @Composable () -> Unit
) {
    IconButton(
        icon = content,
        onClick = onClick,
        contentDescription = contentDescription,
        modifier = modifier,
        style = style,
        enabled = enabled
    )
}

@Composable
fun UiSetSwitch(
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
    contentDescription: String? = null
) {
    Switch(
        checked = checked,
        onCheckedChange = onCheckedChange,
        modifier = modifier,
        contentDescription = contentDescription
    )
}

@Composable
fun UiSetSlider(
    value: Float,
    onValueChange: (Float) -> Unit,
    valueRange: ClosedFloatingPointRange<Float>,
    modifier: Modifier = Modifier,
    onValueChangeFinished: (() -> Unit)? = null
) {
    Slider(
        value = value,
        onValueChange = onValueChange,
        modifier = modifier,
        valueRange = valueRange,
        onValueChangeFinished = onValueChangeFinished
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
    confirmEnabled: Boolean = true
) {
    BasicDialog(
        title = title,
        description = text,
        primaryAction = DialogAction(
            label = confirmLabel,
            onClick = onConfirm,
            enabled = confirmEnabled,
            destructive = destructive
        ),
        onDismissRequest = onDismiss,
        secondaryAction = DialogAction(
            label = dismissLabel,
            onClick = onDismiss
        )
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
    supportingText: String? = null
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
        keyboardType = keyboardType
    )
}

/**
 * Copy-button glyph: UI Set's check once copied, else the copy glyph.
 * UI Set ships no copy icon, so that one is a vendored vector drawable
 * rather than a reason to keep material-icons-extended.
 */
@Composable
fun UiSetCopyIcon(copied: Boolean) {
    if (copied) {
        Icon(Icons.Regular.CheckAlt, contentDescription = null)
    } else {
        Icon(painterResource(R.drawable.ic_content_copy_24), contentDescription = null)
    }
}

/**
 * The accent swatch as a text color. This is the same iOS blue the root
 * theme accents the UiSet scheme with (see ZeroZeroWidgetTheme) — read
 * from a const rather than the scheme because UiSet keeps its accent
 * container brush internal. For accent-colored text on surfaces — the old
 * `primary` text role.
 */
internal val UiSetAccent = Color(0xFF0A84FF)

fun uiSetAccent(): Color = UiSetAccent
