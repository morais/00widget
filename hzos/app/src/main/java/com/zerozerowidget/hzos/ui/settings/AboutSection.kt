package com.zerozerowidget.hzos.ui.settings

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import com.zerozerowidget.hzos.BuildConfig
import com.zerozerowidget.hzos.ui.cards.GlassCard
import com.zerozerowidget.hzos.ui.openDeepLink
import com.zerozerowidget.hzos.ui.theme.spacing
import metavrx.uiset.compose.Text
import metavrx.uiset.compose.theme.LocalContentColors
import metavrx.uiset.compose.theme.LocalTypography

/**
 * The About row's "Version 1.5 (2026092812-abc1234)". A composition local
 * so the layout screenshot test can pin it: the real value changes with
 * every commit and every hour.
 */
internal val LocalBuildStamp = staticCompositionLocalOf {
    "Version ${BuildConfig.VERSION_NAME} " +
        "(${BuildConfig.VERSION_CODE}-" +
        "${BuildConfig.GIT_SHA})"
}

/**
 * About: version (tap → developer), privacy, terms. URLs come from the
 * gitignored store config; a blank URL hides its row, so clones without
 * listing metadata show version alone.
 */
@Composable
internal fun AboutSection(cardAlpha: Float, onOpenDeveloper: () -> Unit) {
    val context = LocalContext.current
    GlassCard(cardAlpha = cardAlpha) {
        Column(verticalArrangement = Arrangement.spacedBy(spacing.xSmall)) {
            Text("About", style = LocalTypography.current.title)
            VersionRow(onOpenDeveloper = onOpenDeveloper)
            val privacy = BuildConfig.PRIVACY_URL
            if (privacy.isNotBlank()) {
                LinkRow(label = "Privacy policy") { openDeepLink(context, privacy) }
            }
            val terms = BuildConfig.TERMS_URL
            if (terms.isNotBlank()) {
                LinkRow(label = "Terms of service") { openDeepLink(context, terms) }
            }
        }
    }
}

/**
 * Look and Pinch target floor for Settings rows that are a line of text.
 * Sized to the text, the About rows were about 20dp and the simulator's
 * interactive-element overlay showed their outlines overlapping; padded
 * rows came out a dp or two short once their text was small.
 */
internal val MIN_ROW_HEIGHT = 48.dp

@Composable
internal fun LinkRow(label: String, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(role = Role.Button, onClick = onClick)
            .heightIn(min = MIN_ROW_HEIGHT),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(
            label,
            style = LocalTypography.current.body,
            color = LocalContentColors.current.secondary,
            modifier = Modifier.weight(1f)
        )
        Text(
            ">",
            style = LocalTypography.current.body,
            color = LocalContentColors.current.secondary
        )
    }
}

@Composable
internal fun VersionRow(onOpenDeveloper: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(role = Role.Button, onClick = onOpenDeveloper)
            .heightIn(min = MIN_ROW_HEIGHT),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(
            LocalBuildStamp.current,
            style = LocalTypography.current.body,
            color = LocalContentColors.current.secondary,
            modifier = Modifier.weight(1f)
        )
        Text(
            ">",
            style = LocalTypography.current.body,
            color = LocalContentColors.current.secondary
        )
    }
}
