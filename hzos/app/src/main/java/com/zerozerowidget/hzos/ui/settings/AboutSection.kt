package com.zerozerowidget.hzos.ui.settings

import androidx.compose.runtime.staticCompositionLocalOf
import com.zerozerowidget.hzos.ui.theme.spacing
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import metavrx.uiset.compose.Text
import metavrx.uiset.compose.theme.LocalContentColors
import metavrx.uiset.compose.theme.LocalTypography
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import com.zerozerowidget.hzos.ui.cards.GlassCard
import com.zerozerowidget.hzos.ui.openDeepLink

/**
 * The About row's "Version 1.5 (2026092812-abc1234)". A composition local
 * so the layout screenshot test can pin it: the real value changes with
 * every commit and every hour.
 */
internal val LocalBuildStamp = staticCompositionLocalOf {
    "Version ${com.zerozerowidget.hzos.BuildConfig.VERSION_NAME} " +
        "(${com.zerozerowidget.hzos.BuildConfig.VERSION_CODE}-" +
        "${com.zerozerowidget.hzos.BuildConfig.GIT_SHA})"
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
            val privacy = com.zerozerowidget.hzos.BuildConfig.PRIVACY_URL
            if (privacy.isNotBlank()) {
                LinkRow(label = "Privacy policy") { openDeepLink(context, privacy) }
            }
            val terms = com.zerozerowidget.hzos.BuildConfig.TERMS_URL
            if (terms.isNotBlank()) {
                LinkRow(label = "Terms of service") { openDeepLink(context, terms) }
            }
        }
    }
}

@Composable
internal fun LinkRow(label: String, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            label,
            style = LocalTypography.current.bodySmall,
            color = LocalContentColors.current.secondary,
            modifier = Modifier.weight(1f),
        )
        Text(
            ">",
            style = LocalTypography.current.body,
            color = LocalContentColors.current.secondary,
        )
    }
}

@Composable
internal fun VersionRow(onOpenDeveloper: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onOpenDeveloper),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            LocalBuildStamp.current,
            style = LocalTypography.current.bodySmall,
            color = LocalContentColors.current.secondary,
            modifier = Modifier.weight(1f),
        )
        Text(
            ">",
            style = LocalTypography.current.body,
            color = LocalContentColors.current.secondary,
        )
    }
}
