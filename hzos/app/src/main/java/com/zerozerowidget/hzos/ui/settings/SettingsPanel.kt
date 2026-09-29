package com.zerozerowidget.hzos.ui.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.zerozerowidget.hzos.BuildConfig
import com.zerozerowidget.hzos.ZeroZeroWidgetApp
import com.zerozerowidget.hzos.auth.ensureMetaUserMatches
import com.zerozerowidget.hzos.data.ConnectionStore
import com.zerozerowidget.hzos.ui.PanelBreakpoints
import com.zerozerowidget.hzos.ui.PanelPrefs
import com.zerozerowidget.hzos.ui.agent.AgentConnectPanel
import com.zerozerowidget.hzos.ui.cardAlphaState
import com.zerozerowidget.hzos.ui.cards.GlassCard
import com.zerozerowidget.hzos.ui.connectionState
import com.zerozerowidget.hzos.ui.theme.panelBackground
import com.zerozerowidget.hzos.ui.theme.spacing
import com.zerozerowidget.hzos.ui.uiset.UiSetIconButton
import com.zerozerowidget.hzos.ui.uiset.UiSetSecondaryButton
import kotlinx.coroutines.launch
import metavrx.uiset.compose.Icon as UiSetIcon
import metavrx.uiset.compose.Text
import metavrx.uiset.compose.navigation.SideNavItem
import metavrx.uiset.compose.theme.LocalTypography
import metavrx.uiset.compose.theme.icons.Icons as UiSetIcons

internal enum class SettingsDestination { ROOT, AGENT, DEVELOPER, SUBSCRIPTION, ACCOUNT }

internal fun titleOf(destination: SettingsDestination): String = when (destination) {
    SettingsDestination.ROOT -> "Settings"
    SettingsDestination.AGENT -> "Connect an agent"
    SettingsDestination.DEVELOPER -> "Developer"
    SettingsDestination.SUBSCRIPTION -> "Subscription"
    SettingsDestination.ACCOUNT -> "Account and access"
}

@Composable
internal fun railIcon(destination: SettingsDestination) = when (destination) {
    SettingsDestination.ROOT -> UiSetIcons.Regular.Settings
    SettingsDestination.AGENT -> UiSetIcons.Regular.Chat
    SettingsDestination.DEVELOPER -> UiSetIcons.Regular.CommandCenter
    SettingsDestination.SUBSCRIPTION -> UiSetIcons.Regular.Purchase
    SettingsDestination.ACCOUNT -> UiSetIcons.Regular.Profile
}

/**
 * Settings is one panel with drill-in destinations, not separate shell
 * panels: the root (connection, agent doorway, about), the agent guide,
 * and the developer screen, with a back button between them.
 */
@Composable
fun SettingsPanel(
    app: ZeroZeroWidgetApp,
    onClose: () -> Unit,
    onSendAuthUrl: (authUrl: String, onSent: (Boolean) -> Unit) -> Unit,
    signInRequest: Int = 0,
    onSignInRequestConsumed: () -> Unit = {}
) {
    var destination by remember { mutableStateOf(SettingsDestination.ROOT) }
    val title = titleOf(destination)
    // A dashboard "Sign in" press lands here mid-flow: come back to the
    // root where the sign-in section lives, wherever the panel was left.
    LaunchedEffect(signInRequest) {
        if (signInRequest > 0) destination = SettingsDestination.ROOT
    }
    val connection by app.connectionStore.connectionState()
    // What the rail offers mirrors what the root links to: account screens
    // only when signed in, subscription only when the build sells one.
    // Developer stays behind the version-number tap, as on iOS.
    val signedIn = connection.apiKey.isNotBlank()
    // Signing out, however it happens (the Sign out button, a Meta account
    // switch, a server change), leaves the screens that only exist signed
    // in, landing on the root's signed-out Server card. Sign out used to
    // leave you on Account and access, whose button then did nothing.
    LaunchedEffect(signedIn) {
        if (!signedIn && destination in SIGNED_IN_ONLY) destination = SettingsDestination.ROOT
    }
    val railDestinations = buildList {
        add(SettingsDestination.ROOT)
        add(SettingsDestination.AGENT)
        if (signedIn) add(SettingsDestination.ACCOUNT)
        if (signedIn && BuildConfig.SUBSCRIPTIONS_ENABLED) {
            add(SettingsDestination.SUBSCRIPTION)
        }
    }

    BoxWithConstraints(Modifier.fillMaxSize().panelBackground()) {
        // Wide panels get a UI Set side-nav rail: one pinch per destination
        // and no Back. Below the breakpoint the drill-in stays, since a rail
        // would take a third of a 480dp panel.
        val showRail = maxWidth >= PanelBreakpoints.SettingsRail
        Row(Modifier.fillMaxSize()) {
            if (showRail) {
                Column(
                    Modifier
                        .width(220.dp)
                        .padding(start = spacing.medium, top = spacing.twoXLarge),
                    verticalArrangement = Arrangement.spacedBy(spacing.xSmall)
                ) {
                    railDestinations.forEach { dest ->
                        SideNavItem(
                            icon = { UiSetIcon(railIcon(dest), contentDescription = null) },
                            onClick = { destination = dest },
                            primaryLabel = titleOf(dest),
                            selected = destination == dest
                        )
                    }
                }
            }
            Column(Modifier.weight(1f).fillMaxHeight()) {
                // Pinned: Back, title, and close stay put while the destination
                // below scrolls — the agent guide is long enough to lose them.
                Row(
                    Modifier
                        .fillMaxWidth()
                        .padding(start = spacing.twoXLarge, end = spacing.twoXLarge, top = spacing.twoXLarge),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    if (destination != SettingsDestination.ROOT && !(showRail && destination in railDestinations)) {
                        UiSetSecondaryButton("Back", onClick = { destination = SettingsDestination.ROOT })
                        Spacer(Modifier.width(spacing.small))
                    }
                    Text(
                        title,
                        style = LocalTypography.current.headline,
                        modifier = Modifier.weight(1f),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                    UiSetIconButton(onClick = onClose, contentDescription = "Close") {
                        UiSetIcon(UiSetIcons.Regular.Close, contentDescription = null)
                    }
                }

                Column(
                    Modifier
                        .weight(1f)
                        .verticalScroll(rememberScrollState())
                        .padding(start = spacing.twoXLarge, end = spacing.twoXLarge, top = spacing.medium, bottom = spacing.twoXLarge),
                    verticalArrangement = Arrangement.spacedBy(spacing.medium)
                ) {
                    when (destination) {
                        SettingsDestination.ROOT -> SettingsRoot(
                            app = app,
                            onOpenAgent = { destination = SettingsDestination.AGENT },
                            onOpenDeveloper = { destination = SettingsDestination.DEVELOPER },
                            onOpenSubscription = { destination = SettingsDestination.SUBSCRIPTION },
                            onOpenAccountAccess = { destination = SettingsDestination.ACCOUNT },
                            onSendAuthUrl = onSendAuthUrl,
                            signInRequest = signInRequest,
                            onSignInRequestConsumed = onSignInRequestConsumed
                        )

                        SettingsDestination.AGENT -> AgentConnectPanel(app = app)

                        SettingsDestination.DEVELOPER -> DeveloperPanel(app = app)

                        SettingsDestination.SUBSCRIPTION -> SubscriptionSection(app = app)

                        SettingsDestination.ACCOUNT -> AccountAccessDestination(
                            app = app,
                            // Delete/unlink ends the session: land back on the root
                            // so Settings shows the signed-out Server card, not this
                            // screen with dead credentials behind it.
                            onSignedOut = { destination = SettingsDestination.ROOT }
                        )
                    }
                }
            }
        }
    }
}

@Composable
internal fun SettingsRoot(
    app: ZeroZeroWidgetApp,
    onOpenAgent: () -> Unit,
    onOpenDeveloper: () -> Unit,
    onOpenSubscription: () -> Unit,
    onOpenAccountAccess: () -> Unit,
    onSendAuthUrl: (authUrl: String, onSent: (Boolean) -> Unit) -> Unit,
    signInRequest: Int = 0,
    onSignInRequestConsumed: () -> Unit = {}
) {
    val scope = rememberCoroutineScope()
    val connection by app.connectionStore.connectionState()
    val signedIn = connection.apiKey.isNotBlank()
    val cardAlpha by app.panelPrefs.cardAlphaState()

    // Same switch check as the dashboard foreground: opening Settings on a
    // switched account lands on sign-in instead of a stranger's session.
    LaunchedEffect(connection.apiKey) {
        ensureMetaUserMatches(app)
    }

    Column(verticalArrangement = Arrangement.spacedBy(spacing.medium)) {
        GlassCard(cardAlpha = cardAlpha) {
            Column(verticalArrangement = Arrangement.spacedBy(spacing.medium)) {
                // Section title like every other card on this screen —
                // "Server", as on iOS.
                Text("Server", style = LocalTypography.current.title)
                if (!signedIn) {
                    HorizonSignInSection(
                        app = app,
                        onSendAuthUrl = onSendAuthUrl,
                        signInRequest = signInRequest,
                        onSignInRequestConsumed = onSignInRequestConsumed
                    )
                } else {
                    AccountSection(
                        app = app,
                        // Purchase flow lives behind the build flag; without
                        // it the status row is display-only, as before.
                        onOpenSubscription = if (BuildConfig.SUBSCRIPTIONS_ENABLED) {
                            onOpenSubscription
                        } else {
                            null
                        },
                        onOpenAccountAccess = onOpenAccountAccess
                    )
                }
            }
        }

        Spacer(Modifier.height(spacing.xSmall))
        AgentConfigSection(app = app, cardAlpha = cardAlpha, onOpenAgentConnect = onOpenAgent)
        Spacer(Modifier.height(spacing.xSmall))
        AboutSection(cardAlpha = cardAlpha, onOpenDeveloper = onOpenDeveloper)
    }
}

/** Destinations that only make sense with a credential. */
private val SIGNED_IN_ONLY = setOf(SettingsDestination.ACCOUNT, SettingsDestination.SUBSCRIPTION)
