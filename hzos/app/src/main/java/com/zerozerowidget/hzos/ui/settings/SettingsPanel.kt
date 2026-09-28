package com.zerozerowidget.hzos.ui.settings

import androidx.compose.runtime.staticCompositionLocalOf
import com.zerozerowidget.hzos.ui.PanelBreakpoints
import com.zerozerowidget.hzos.ui.theme.spacing
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.foundation.clickable
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.text.selection.SelectionContainer
import metavrx.uiset.compose.Icon as UiSetIcon
import metavrx.uiset.compose.dialog.BasicDialog
import metavrx.uiset.compose.dialog.DialogAction
import metavrx.uiset.compose.dialog.DialogProgress
import metavrx.uiset.compose.navigation.SideNavItem
import metavrx.uiset.compose.Text
import metavrx.uiset.compose.theme.LocalColorScheme
import metavrx.uiset.compose.theme.LocalContentColors
import com.zerozerowidget.hzos.ui.theme.panelBackground
import metavrx.uiset.compose.theme.LocalTypography
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.zerozerowidget.hzos.ZeroZeroWidgetApp
import com.zerozerowidget.hzos.auth.ensureMetaUserMatches
import com.zerozerowidget.hzos.data.ConnectionStore
import com.zerozerowidget.hzos.data.DeviceAuthApi
import com.zerozerowidget.hzos.data.DummyAccountData
import com.zerozerowidget.hzos.data.HorizonOutcome
import com.zerozerowidget.hzos.data.SubscriptionState
import com.zerozerowidget.hzos.data.ZeroWidgetApi
import com.zerozerowidget.hzos.data.AccountIdAction
import com.zerozerowidget.hzos.data.accountIdAction
import com.zerozerowidget.hzos.data.awaitDeviceToken
import com.zerozerowidget.hzos.data.horizonSignInBody
import com.zerozerowidget.hzos.data.runHorizonSignIn
import com.zerozerowidget.hzos.ui.agent.AgentConnectPanel
import com.zerozerowidget.hzos.ui.cards.GlassCard
import com.zerozerowidget.hzos.ui.openDeepLink
import com.zerozerowidget.hzos.ui.uiset.UiSetConfirmDialog
import com.zerozerowidget.hzos.ui.uiset.UiSetDestructiveButton
import com.zerozerowidget.hzos.ui.uiset.UiSetCopyIcon
import com.zerozerowidget.hzos.ui.uiset.UiSetIconButton
import com.zerozerowidget.hzos.ui.uiset.UiSetPrimaryButton
import com.zerozerowidget.hzos.ui.uiset.UiSetSecondaryButton
import com.zerozerowidget.hzos.ui.uiset.UiSetSlider
import com.zerozerowidget.hzos.ui.uiset.UiSetSwitch
import com.zerozerowidget.hzos.ui.uiset.UiSetTextField
import com.zerozerowidget.hzos.ui.uiset.uiSetAccent
import metavrx.uiset.compose.theme.icons.Icons as UiSetIcons
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private enum class HorizonPhase { IDLE, PROVING, CHOICE, WAITING }

private enum class SettingsDestination { ROOT, AGENT, DEVELOPER, SUBSCRIPTION, ACCOUNT }

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

private fun titleOf(destination: SettingsDestination): String = when (destination) {
    SettingsDestination.ROOT -> "Settings"
    SettingsDestination.AGENT -> "Connect an agent"
    SettingsDestination.DEVELOPER -> "Developer"
    SettingsDestination.SUBSCRIPTION -> "Subscription"
    SettingsDestination.ACCOUNT -> "Account and access"
}

@Composable
private fun railIcon(destination: SettingsDestination) = when (destination) {
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
    onSignInRequestConsumed: () -> Unit = {},
) {
    var destination by remember { mutableStateOf(SettingsDestination.ROOT) }
    val title = titleOf(destination)
    // A dashboard "Sign in" press lands here mid-flow: come back to the
    // root where the sign-in section lives, wherever the panel was left.
    LaunchedEffect(signInRequest) {
        if (signInRequest > 0) destination = SettingsDestination.ROOT
    }
    val connection by app.connectionStore.connection.collectAsState(
        initial = ConnectionStore.Connection("", ""),
    )
    // What the rail offers mirrors what the root links to: account screens
    // only when signed in, subscription only when the build sells one.
    // Developer stays behind the version-number tap, as on iOS.
    val signedIn = connection.apiKey.isNotBlank()
    val railDestinations = buildList {
        add(SettingsDestination.ROOT)
        add(SettingsDestination.AGENT)
        if (signedIn) add(SettingsDestination.ACCOUNT)
        if (signedIn && com.zerozerowidget.hzos.BuildConfig.SUBSCRIPTIONS_ENABLED) {
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
            verticalArrangement = Arrangement.spacedBy(spacing.xSmall),
        ) {
            railDestinations.forEach { dest ->
                SideNavItem(
                    icon = { UiSetIcon(railIcon(dest), contentDescription = null) },
                    onClick = { destination = dest },
                    primaryLabel = titleOf(dest),
                    selected = destination == dest,
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
            verticalAlignment = Alignment.CenterVertically,
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
                overflow = TextOverflow.Ellipsis,
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
            verticalArrangement = Arrangement.spacedBy(spacing.medium),
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
                onSignInRequestConsumed = onSignInRequestConsumed,
            )
            SettingsDestination.AGENT -> AgentConnectPanel(app = app)
            SettingsDestination.DEVELOPER -> DeveloperPanel(app = app)
            SettingsDestination.SUBSCRIPTION -> SubscriptionSection(app = app)
            SettingsDestination.ACCOUNT -> AccountAccessDestination(
                app = app,
                // Delete/unlink ends the session: land back on the root
                // so Settings shows the signed-out Server card, not this
                // screen with dead credentials behind it.
                onSignedOut = { destination = SettingsDestination.ROOT },
            )
        }
        }
    }
    }
    }
}

@Composable
private fun SettingsRoot(
    app: ZeroZeroWidgetApp,
    onOpenAgent: () -> Unit,
    onOpenDeveloper: () -> Unit,
    onOpenSubscription: () -> Unit,
    onOpenAccountAccess: () -> Unit,
    onSendAuthUrl: (authUrl: String, onSent: (Boolean) -> Unit) -> Unit,
    signInRequest: Int = 0,
    onSignInRequestConsumed: () -> Unit = {},
) {
    val scope = rememberCoroutineScope()
    val connection by app.connectionStore.connection.collectAsState(
        initial = ConnectionStore.Connection("", ""),
    )
    val signedIn = connection.apiKey.isNotBlank()
    val cardAlpha by app.panelPrefs.cardAlpha.collectAsState(
        initial = com.zerozerowidget.hzos.ui.PanelPrefs.DEFAULT_CARD_ALPHA,
    )

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
                        onSignedIn = { base, token, metaUserId ->
                            scope.launch {
                                app.connectionStore.save(base, token, metaUserId)
                                app.repository.refresh()
                            }
                        },
                        signInRequest = signInRequest,
                        onSignInRequestConsumed = onSignInRequestConsumed,
                    )
                } else {
                    AccountSection(
                        app = app,
                        // Purchase flow lives behind the build flag; without
                        // it the status row is display-only, as before.
                        onOpenSubscription = if (com.zerozerowidget.hzos.BuildConfig.SUBSCRIPTIONS_ENABLED) {
                            onOpenSubscription
                        } else {
                            null
                        },
                        onOpenAccountAccess = onOpenAccountAccess,
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

/**
 * Device sign-out plus delete-or-unlink, grouped like iOS Account and
 * access: the things that end or move a session live together, one tap
 * past the Server rows.
 */
@Composable
private fun AccountAccessDestination(app: ZeroZeroWidgetApp, onSignedOut: () -> Unit) {
    val scope = rememberCoroutineScope()
    val cardAlpha by app.panelPrefs.cardAlpha.collectAsState(
        initial = com.zerozerowidget.hzos.ui.PanelPrefs.DEFAULT_CARD_ALPHA,
    )

    Column(verticalArrangement = Arrangement.spacedBy(spacing.medium)) {
        GlassCard(cardAlpha = cardAlpha) {
            Column(verticalArrangement = Arrangement.spacedBy(spacing.small)) {
                Text("This device", style = LocalTypography.current.title)
                Text(
                    "Signing out forgets this device's credential and clears " +
                        "its cards straight away.",
                    style = LocalTypography.current.bodySmall,
                    color = LocalContentColors.current.secondary,
                )
                UiSetSecondaryButton(
                    "Sign out",
                    onClick = {
                        scope.launch {
                            app.connectionStore.clear()
                            app.repository.clearServerData()
                        }
                    },
                )
            }
        }
        Spacer(Modifier.height(spacing.xSmall))
        GlassCard(cardAlpha = cardAlpha) {
            RotateAgentTokensSection(app = app)
        }
        Spacer(Modifier.height(spacing.xSmall))
        AccountAccessSection(app = app, cardAlpha = cardAlpha, onSignedOut = onSignedOut)
    }
}

/**
 * Who this device is signed in as, asked live: a reinstall authenticates
 * with nothing cached to show, so the server is the source of truth.
 * Email like iOS, falling back to the account display name when there is
 * no email (Horizon-created tenants have none) — never the raw Meta id,
 * which is an opaque key, not a name. Plus the subscription status beside
 * it when the deployment sells any — with subscriptions off the server
 * answers 404 and the row stays away. The status row doubles as the
 * doorway to the purchase screen while a purchase flow is compiled in.
 * Anything failing degrades to the plain row.
 */
@Composable
private fun AccountSection(
    app: ZeroZeroWidgetApp,
    onOpenSubscription: (() -> Unit)? = null,
    onOpenAccountAccess: () -> Unit,
) {
    var accountName by remember { mutableStateOf<String?>(null) }
    var loaded by remember { mutableStateOf(false) }
    var subscription by remember { mutableStateOf<SubscriptionState?>(null) }
    var subscriptionAnswered by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        try {
            val api = app.authedApi() ?: return@LaunchedEffect
            // Parallel: account and subscription are independent reads,
            // and sequential await was the visible fill-up. Both states
            // land together below, so the rows below never reshape twice.
            coroutineScope {
                val accountDeferred = async { api.fetchAccount() }
                val subscriptionDeferred = async { api.fetchSubscription() }
                val account = accountDeferred.await()
                accountName = account.ownerEmail?.takeIf { it.isNotBlank() }
                    ?: account.displayName?.takeIf { it.isNotBlank() }
                subscription = subscriptionDeferred.await()
            }
        } catch (e: Exception) {
            // Anything failing degrades to the plain row (see below).
        } finally {
            loaded = true
            subscriptionAnswered = true
        }
    }

    Column(verticalArrangement = Arrangement.spacedBy(spacing.xSmall)) {
        // Same roomy row as the doors below: without the padding this
        // line reads visually smaller than its neighbours. The shape
        // never changes while loading — label plus a Loading… value —
        // so the row below does not move when the name arrives.
        Row(
            Modifier.fillMaxWidth().padding(vertical = spacing.medium),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (loaded && accountName.isNullOrBlank()) {
                Text(
                    "Signed in.",
                    style = LocalTypography.current.body,
                    modifier = Modifier.weight(1f),
                )
            } else {
                Text(
                    "Signed in as",
                    style = LocalTypography.current.body,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    if (!loaded) "Loading…" else accountName!!,
                    style = LocalTypography.current.bodySmall,
                    color = LocalContentColors.current.secondary,
                )
            }
        }
        if (!subscriptionAnswered) {
            // Reserved while the parallel fetch answers: without it the
            // Account door jumps when this row arrives or stays away.
            Row(
                Modifier.fillMaxWidth().padding(vertical = spacing.medium),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    "Subscription",
                    style = LocalTypography.current.body,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    "Loading…",
                    style = LocalTypography.current.bodySmall,
                    color = LocalContentColors.current.secondary,
                )
            }
        } else if (subscription != null) {
            // Doorway to the purchase screen when the build sells anything,
            // a plain status row otherwise — like iOS, where Subscription
            // is a NavigationLink only with the flag on.
            // Roomy rows: these are the two doors out of this card and
            // should take a ray tap without precision.
            val rowModifier = if (onOpenSubscription != null) {
                Modifier
                    .fillMaxWidth()
                    .clickable(onClick = onOpenSubscription)
                    .padding(vertical = spacing.medium)
            } else {
                Modifier.fillMaxWidth()
            }
            Row(rowModifier, verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "Subscription",
                    style = LocalTypography.current.body,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    subscription!!.displayLabel,
                    style = LocalTypography.current.bodySmall,
                    color = if (subscription!!.needsAttention) {
                        LocalColorScheme.current.negative.content
                    } else {
                        LocalContentColors.current.secondary
                    },
                )
                if (onOpenSubscription != null) {
                    Text(
                        ">",
                        style = LocalTypography.current.body,
                        color = LocalContentColors.current.secondary,
                        modifier = Modifier.padding(start = spacing.small),
                    )
                }
            }
        }
        Row(
            Modifier
                .fillMaxWidth()
                .clickable(onClick = onOpenAccountAccess)
                .padding(vertical = spacing.medium),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                "Account and access",
                style = LocalTypography.current.body,
                modifier = Modifier.weight(1f),
            )
            Text(
                ">",
                style = LocalTypography.current.body,
                color = LocalContentColors.current.secondary,
            )
        }
    }
}

/**
 * Delete-or-unlink for the account, decided by its login identities (see
 * [accountIdAction]): Horizon-only accounts can only be deleted, Apple-
 * linked ones only unlinked. Absent identity data (older Workers) offers
 * neither. Either success clears the local store — the token dies with
 * the account or the link — and refreshes into the signed-out view.
 */
@Composable
private fun AccountAccessSection(app: ZeroZeroWidgetApp, cardAlpha: Float, onSignedOut: () -> Unit) {
    val scope = rememberCoroutineScope()
    var action by remember { mutableStateOf<AccountIdAction?>(null) }
    var confirming by remember { mutableStateOf<AccountIdAction?>(null) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(Unit) {
        action = try {
            val api = app.authedApi()
            if (api == null) {
                AccountIdAction.NONE
            } else {
                accountIdAction(api.fetchAccount().identities.map { it.provider })
            }
        } catch (e: Exception) {
            AccountIdAction.NONE
        }
    }

    // The identity answers over the network: hold a Loading… card
    // instead of nothing, so the screen above does not jump when the
    // delete-or-unlink card arrives. Nothing determinable, nothing
    // offered. Hooks stay above this return.
    if (action == null) {
        GlassCard(cardAlpha = cardAlpha) {
            Text(
                "Loading…",
                style = LocalTypography.current.body,
                color = LocalContentColors.current.secondary,
            )
        }
        return
    }
    if (action == AccountIdAction.NONE) return

    suspend fun api(): ZeroWidgetApi =
        app.authedApi() ?: throw IllegalStateException("Not connected.")

    fun execute(act: AccountIdAction) {
        if (busy) return
        confirming = null
        busy = true
        error = null
        scope.launch {
            // Every path that kills the local credential lands on the
            // Settings root: it is the screen that shows the signed-out
            // Server card, while this one would keep a dead session.
            suspend fun landSignedOut() {
                app.connectionStore.clear()
                app.repository.clearServerData()
                onSignedOut()
            }
            try {
                if (act == AccountIdAction.DELETE) {
                    api().deleteAccount()
                    landSignedOut()
                } else {
                    val (status, body) = api().unlinkHorizonAccount()
                    if (status in 200..299) {
                        landSignedOut()
                    } else if (status == 401 || status == 404) {
                        // Dead credential or already-gone link: the session
                        // is useless either way, so land signed out. A 404
                        // from a Worker predating the endpoint reads the
                        // same — both mean there is nothing to unlink.
                        landSignedOut()
                    } else if (status == 409) {
                        throw IllegalStateException(
                            "Horizon is the only way into this account — delete it instead.",
                        )
                    } else {
                        val serverError = """"error"\s*:\s*"([^"]*)""""
                            .toRegex().find(body)?.groupValues?.getOrNull(1)
                        throw IllegalStateException(
                            serverError?.takeIf { it.isNotBlank() } ?: "Request failed ($status).",
                        )
                    }
                }
                app.repository.refresh()
            } catch (e: ZeroWidgetApi.ApiException) {
                // Delete's only failure with a usable session behind it is
                // worth naming; anything else (401/404) already landed
                // signed out above or means the account is gone, so the
                // local clear stands and no error shows.
                if (act == AccountIdAction.DELETE && e.status !in listOf(401, 404)) {
                    error = (e.message ?: "Delete failed.").take(200)
                } else if (act == AccountIdAction.DELETE) {
                    landSignedOut()
                } else {
                    error = (e.message ?: "Request failed.").take(200)
                }
            } catch (e: Exception) {
                error = (e.message ?: e.javaClass.simpleName).take(200)
            } finally {
                busy = false
            }
        }
    }

    val isDelete = action == AccountIdAction.DELETE
    GlassCard(cardAlpha = cardAlpha) {
        Column(verticalArrangement = Arrangement.spacedBy(spacing.small)) {
            Text(
                if (isDelete) {
                    "Horizon is the only way into this account. Deleting removes " +
                        "its cards, activities, tokens, and the account itself — " +
                        "it cannot be undone."
                } else {
                    "This account also uses Sign in with Apple, which keeps " +
                        "working. Unlinking removes this headset's Meta identity " +
                        "and signs this device out."
                },
                style = LocalTypography.current.bodySmall,
                color = LocalContentColors.current.secondary,
            )
            error?.let {
                Text(it, style = LocalTypography.current.bodySmall, color = LocalColorScheme.current.negative.content)
            }
            if (isDelete) {
                UiSetDestructiveButton(
                    if (busy) "Working…" else "Delete account",
                    onClick = { confirming = action },
                    enabled = !busy,
                )
            } else {
                UiSetSecondaryButton(
                    if (busy) "Working…" else "Unlink this headset",
                    onClick = { confirming = action },
                    enabled = !busy,
                )
            }
        }
    }

    if (confirming != null) {
        val target = confirming!!
        val destructive = target == AccountIdAction.DELETE
        UiSetConfirmDialog(
            title = if (destructive) "Delete this account?" else "Unlink this headset?",
            text = if (destructive) {
                "Everything goes: cards, activities, tokens, the account itself."
            } else {
                "This Meta identity loses access to the account. Apple sign-in is unaffected."
            },
            confirmLabel = if (destructive) "Delete" else "Unlink",
            onConfirm = { execute(target) },
            dismissLabel = "Cancel",
            onDismiss = { if (!busy) confirming = null },
            destructive = destructive,
            confirmEnabled = !busy,
        )
    }
}

/**
 * About: version (tap → developer), privacy, terms. URLs come from the
 * gitignored store config; a blank URL hides its row, so clones without
 * listing metadata show version alone.
 */
@Composable
private fun AboutSection(cardAlpha: Float, onOpenDeveloper: () -> Unit) {
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
private fun LinkRow(label: String, onClick: () -> Unit) {
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

/**
 * Agent config entry: the "Dear agent" integration text iOS Settings shows,
 * plus the connector doorway below it.
 *
 * Signed out, the text names the server and says the token arrives after
 * sign-in; signed in, it names the token too. The displayed string and the
 * copied string are deliberately the same: a copy button that quietly puts
 * the real token on the clipboard while the screen shows a placeholder is
 * how the token ends up pasted in front of whoever the placeholder was
 * hiding it from.
 */
@Composable
private fun AgentConfigSection(app: ZeroZeroWidgetApp, cardAlpha: Float, onOpenAgentConnect: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val connection by app.connectionStore.connection.collectAsState(
        initial = ConnectionStore.Connection("", ""),
    )
    val showDummy by app.panelPrefs.showDummyAccountData.collectAsState(initial = false)
    var copied by remember { mutableStateOf(false) }
    val baseUrl = ConnectionStore.effectiveBaseUrl(connection.baseUrl).orEmpty()
    val signedIn = connection.apiKey.isNotBlank()
    val displayedToken = if (showDummy) DummyAccountData.API_KEY else connection.apiKey
    val agentConfig = if (!signedIn) {
        "Dear agent: To integrate with 00Widget, read the instructions at $baseUrl; " +
            "use that as the base URL. You'll need an authorization token, " +
            "which will be available after you sign in."
    } else {
        "Dear agent: To integrate with 00Widget, read the instructions at $baseUrl; " +
            "use that as the base URL, and use $displayedToken as the authorization token."
    }

    GlassCard(cardAlpha = cardAlpha) {
        Column(verticalArrangement = Arrangement.spacedBy(spacing.small)) {
            Text("Agent config", style = LocalTypography.current.title)
            Row(verticalAlignment = Alignment.Top) {
                SelectionContainer(Modifier.weight(1f)) {
                    Text(
                        agentConfig,
                        style = LocalTypography.current.bodySmall,
                        color = LocalContentColors.current.secondary,
                    )
                }
                UiSetIconButton(
                    onClick = {
                        val clipboard =
                            context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                        clipboard.setPrimaryClip(ClipData.newPlainText("00Widget agent config", agentConfig))
                        copied = true
                        scope.launch {
                            // Acknowledgement of the tap, not a running
                            // clipboard status — matches iOS (10s there).
                            // Unlike iOS there is no pasteboard expiry here,
                            // so the row promises nothing about clearing.
                            delay(10_000)
                            copied = false
                        }
                    },
                    contentDescription = if (copied) "Agent config copied" else "Copy agent config",
                ) {
                    UiSetCopyIcon(copied)
                }
            }
            if (copied) {
                Text(
                    "Copied",
                    style = LocalTypography.current.bodySmall,
                    color = uiSetAccent(),
                )
            }
            // The token path and the connector doorway are the two ways in;
            // the rule keeps them from reading as one paragraph. UiSet
            // ships the divider color but no divider component.
            Box(
                Modifier
                    .fillMaxWidth()
                    .height(1.dp)
                    .background(LocalColorScheme.current.divider),
            )
            Text(
                "Connect assistants (Claude, ChatGPT, OpenCode…) without handing them a token.",
                style = LocalTypography.current.bodySmall,
                color = LocalContentColors.current.secondary,
            )
            UiSetSecondaryButton("Connect an agent", onClick = onOpenAgentConnect)
        }
    }
}

/**
 * Replaces the tokens the account's agents publish with. Logged-in only,
 * mirroring the rotation in iOS AccountExitView — but note what it is and
 * is not: it revokes `publisher`/`agent` purpose keys, never the token
 * shown above (this headset's own sign-in) and never connectors, so the
 * headset stays signed in and assistants stay connected. The replacement
 * is answered once, so it is shown here for handoff, not stored anywhere.
 */
@Composable
private fun RotateAgentTokensSection(app: ZeroZeroWidgetApp) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var confirming by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var rotated by remember { mutableStateOf<com.zerozerowidget.hzos.data.AgentTokenRotation?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var copied by remember { mutableStateOf(false) }

    Column(verticalArrangement = Arrangement.spacedBy(spacing.small)) {
        Text("Agent tokens", style = LocalTypography.current.title)
        Text(
            "Use this if an agent token may have been exposed. Every old agent " +
                "token stops working and one replacement is created — give " +
                "it to your agents. This headset stays signed in.",
            style = LocalTypography.current.bodySmall,
            color = LocalContentColors.current.secondary,
        )
        error?.let {
            Text(it, style = LocalTypography.current.bodySmall, color = LocalColorScheme.current.negative.content)
        }
        rotated?.let {
            Text(
                "Rotated — ${it.revokedAgentTokens} old token(s) revoked. " +
                    "Copy the replacement now; it is shown once.",
                style = LocalTypography.current.bodySmall,
                color = uiSetAccent(),
            )
            Row(verticalAlignment = Alignment.Top) {
                SelectionContainer(Modifier.weight(1f)) {
                    Text(
                        it.token,
                        style = LocalTypography.current.bodySmall,
                        color = LocalContentColors.current.secondary,
                    )
                }
                UiSetIconButton(
                    onClick = {
                        val clipboard =
                            context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                        clipboard.setPrimaryClip(ClipData.newPlainText("00Widget agent token", it.token))
                        copied = true
                        scope.launch {
                            delay(10_000)
                            copied = false
                        }
                    },
                    contentDescription = if (copied) "Agent token copied" else "Copy agent token",
                ) {
                    UiSetCopyIcon(copied)
                }
            }
        }
        UiSetSecondaryButton(
            if (busy) "Rotating…" else "Rotate agent token",
            onClick = { confirming = true },
            enabled = !busy,
        )
    }

    if (confirming) {
        UiSetConfirmDialog(
            title = "Rotate the agent token?",
            text = "Every agent publishing with an old token stops until it gets the replacement.",
            confirmLabel = "Rotate",
            onConfirm = {
                confirming = false
                busy = true
                error = null
                scope.launch {
                    try {
                        val api = app.authedApi() ?: throw IllegalStateException("Not connected.")
                        rotated = api.rotateAgentToken()
                    } catch (e: Exception) {
                        error = (e.message ?: e.javaClass.simpleName).take(200)
                    } finally {
                        busy = false
                    }
                }
            },
            dismissLabel = "Cancel",
            onDismiss = { if (!busy) confirming = false },
            destructive = true,
            confirmEnabled = !busy,
        )
    }
}

@Composable
private fun VersionRow(onOpenDeveloper: () -> Unit) {
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

/**
 * Developer destination: Worker URL, sample-indicator visibility, and panel
 * look. No "provided by the build" note — a readonly field already says
 * it can't be changed.
 */
@Composable
private fun DeveloperPanel(app: ZeroZeroWidgetApp) {
    val scope = rememberCoroutineScope()
    val cardAlpha by app.panelPrefs.cardAlpha.collectAsState(
        initial = com.zerozerowidget.hzos.ui.PanelPrefs.DEFAULT_CARD_ALPHA,
    )
    val hideIndicators by app.panelPrefs.hideSampleIndicators.collectAsState(initial = false)
    val showDummyAccountData by app.panelPrefs.showDummyAccountData.collectAsState(initial = false)
    var sliderAlpha by remember(cardAlpha) { mutableStateOf(cardAlpha) }
    val locked = com.zerozerowidget.hzos.BuildConfig.DEFAULT_BASE_URL.isNotBlank()
    var serverUrl by remember { mutableStateOf("") }
    var savedNote by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) {
        serverUrl = app.connectionStore.current().baseUrl
    }

    GlassCard(cardAlpha = cardAlpha) {
        Column(verticalArrangement = Arrangement.spacedBy(spacing.medium)) {
            Text("Server", style = LocalTypography.current.title)
            if (locked) {
                // No label, no field: the section already says Server, so
                // the URL sits under it as plain text. A disabled field
                // here was chrome around a value nobody can change.
                Text(
                    com.zerozerowidget.hzos.BuildConfig.DEFAULT_BASE_URL,
                    style = LocalTypography.current.bodySmall,
                    color = LocalContentColors.current.secondary,
                )
            } else {
                UiSetTextField(
                    value = serverUrl,
                    label = "",
                    placeholder = "https://…",
                    onValueChange = { serverUrl = it; savedNote = null },
                    modifier = Modifier.fillMaxWidth(),
                    keyboardType = KeyboardType.Uri,
                )
            }
            if (!locked) {
                savedNote?.let {
                    Text(
                        it,
                        style = LocalTypography.current.bodySmall,
                        color = uiSetAccent(),
                    )
                }
                UiSetPrimaryButton(
                    label = "Save server",
                    onClick = {
                        scope.launch {
                            val normalized = ConnectionStore.normalizeBaseUrl(serverUrl)
                            if (normalized == null) {
                                savedNote = "URL must be https (http only for localhost)."
                                return@launch
                            }
                            val current = app.connectionStore.current()
                            app.connectionStore.save(normalized, current.apiKey, current.metaUserId)
                            app.repository.refresh()
                            savedNote = "Saved — dashboard is refreshing."
                        }
                    },
                )
            }
            Text("Screenshots and recordings", style = LocalTypography.current.title)
            Row(
                Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text("Show dummy account data", style = LocalTypography.current.body)
                    Text(
                        "A visibly fake token on the Settings screen instead of your own.",
                        style = LocalTypography.current.bodySmall,
                        color = LocalContentColors.current.secondary,
                    )
                }
                UiSetSwitch(
                    checked = showDummyAccountData,
                    onCheckedChange = { checked ->
                        scope.launch { app.panelPrefs.setShowDummyAccountData(checked) }
                    },
                    contentDescription = "Show dummy account data",
                )
            }
            Row(
                Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text("Hide sample indicators", style = LocalTypography.current.body)
                    Text(
                        "Demo data stays; badges and notice go away.",
                        style = LocalTypography.current.bodySmall,
                        color = LocalContentColors.current.secondary,
                    )
                }
                UiSetSwitch(
                    checked = hideIndicators,
                    onCheckedChange = { checked ->
                        scope.launch { app.panelPrefs.setHideSampleIndicators(checked) }
                    },
                    contentDescription = "Hide sample indicators",
                )
            }
            Text(
                "Dummy account data shows a visibly fake token in Agent config instead of " +
                    "your own. The real token still authorizes every request, and Copy " +
                    "agent config copies what is on screen — so turn this off before " +
                    "handing the token to an agent.",
                style = LocalTypography.current.bodySmall,
                color = LocalContentColors.current.secondary,
            )
            Text("Look", style = LocalTypography.current.title)
            Column(Modifier.fillMaxWidth()) {
                Text("Card opacity", style = LocalTypography.current.body)
                Text(
                    "How solid cards are over passthrough: ${(sliderAlpha * 100).toInt()}%.",
                    style = LocalTypography.current.bodySmall,
                    color = LocalContentColors.current.secondary,
                )
            }
            UiSetSlider(
                value = sliderAlpha,
                onValueChange = { sliderAlpha = it },
                onValueChangeFinished = {
                    scope.launch { app.panelPrefs.setCardAlpha(sliderAlpha) }
                },
                valueRange = 0.5f..1f,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

/**
 * Horizon sign-in: one button proving the headset's Meta identity to the
 * Worker (`POST /v1/auth/horizon`), then either done, an explicit
 * create/join choice, or iPhone approval polling for a join. Hands the
 * resulting token plus the Meta id it was issued for to [onSignedIn], so a
 * later account switch is detectable. Every failure names its cause; the
 * join fallback (manual code entry) doubles as the path where
 * `send_auth_url` is unavailable.
 */
@Composable
private fun HorizonSignInSection(
    app: ZeroZeroWidgetApp,
    onSendAuthUrl: (authUrl: String, onSent: (Boolean) -> Unit) -> Unit,
    onSignedIn: (baseUrl: String, token: String, metaUserId: String) -> Unit,
    signInRequest: Int = 0,
    onSignInRequestConsumed: () -> Unit = {},
) {
    val scope = rememberCoroutineScope()
    var phase by remember { mutableStateOf(HorizonPhase.IDLE) }
    var userCode by remember { mutableStateOf("") }
    var verifyUri by remember { mutableStateOf("") }
    var linkSent by remember { mutableStateOf<Boolean?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var pollJob by remember { mutableStateOf<Job?>(null) }
    // The Meta id the in-flight attempt proved, saved with the token.
    // Retries re-prove (fresh proof, same user), so this trails the latest.
    var attemptUserId by remember { mutableStateOf("") }

    fun cancel() {
        pollJob?.cancel()
        pollJob = null
        phase = HorizonPhase.IDLE
    }

    suspend fun resolveBaseUrl(): String {
        // Server URL resolves here, not in a text field: saved value
        // first, build default second.
        return ConnectionStore.effectiveBaseUrl(app.connectionStore.current().baseUrl)
            ?: throw IllegalArgumentException("No Worker URL configured (Developer screen).")
    }

    fun begin(choice: String?) {
        if (phase != HorizonPhase.IDLE && phase != HorizonPhase.CHOICE) return
        error = null
        phase = HorizonPhase.PROVING
        pollJob = scope.launch {
            try {
                val normalized = resolveBaseUrl()
                // Pre-credential: the key is unused, and the horizon call
                // sends no Authorization header at all.
                val unauthed = ZeroWidgetApi(app.http, normalized, "")
                when (
                    val outcome = runHorizonSignIn(
                        identity = { app.horizonAuth.getMetaIdentity() },
                        request = { userId, proof, ch ->
                            attemptUserId = userId
                            unauthed.postHorizonSignIn(horizonSignInBody(userId, proof, ch))
                        },
                        choice = choice,
                    )
                ) {
                    is HorizonOutcome.SignedIn -> {
                        onSignedIn(normalized, outcome.token, outcome.userId)
                        phase = HorizonPhase.IDLE
                    }
                    HorizonOutcome.NeedChoice -> phase = HorizonPhase.CHOICE
                    is HorizonOutcome.JoinCode -> {
                        val code = outcome.code
                        userCode = code.userCode
                        verifyUri = code.verificationUri
                        linkSent = null
                        phase = HorizonPhase.WAITING
                        onSendAuthUrl(code.completeUri) { sent -> linkSent = sent }
                        val deadline = System.currentTimeMillis() +
                            minOf(code.expiresInSeconds * 1000L, 600_000L)
                        val deviceApi = DeviceAuthApi(app.http, normalized)
                        val token = awaitDeviceToken(
                            deviceApi,
                            code.deviceCode,
                            code.intervalSeconds,
                            deadline,
                        )
                        onSignedIn(normalized, token, attemptUserId)
                        phase = HorizonPhase.IDLE
                    }
                    is HorizonOutcome.Failed -> {
                        error = outcome.message
                        phase = HorizonPhase.IDLE
                    }
                }
            } catch (e: CancellationException) {
                phase = HorizonPhase.IDLE
                throw e
            } catch (e: Exception) {
                android.util.Log.e(
                    "HorizonAuth",
                    "sign-in failed: ${e.javaClass.simpleName}: ${e.message}",
                )
                error = (e.message ?: e.javaClass.simpleName).take(200)
                phase = HorizonPhase.IDLE
            }
        }
    }

    if (!app.horizonAuth.isAvailable) {
        Text(
            "Sign-in needs a Horizon Platform app ID " +
                "(`platformAppId` in hzos/local.properties).",
            style = LocalTypography.current.bodySmall,
            color = LocalContentColors.current.secondary,
        )
        return
    }

    // A dashboard "Sign in" press opens this screen already asking: kick
    // the sign-in flow without waiting for another tap. Once per request —
    // after a cancel the button is the way back in.
    LaunchedEffect(signInRequest) {
        if (signInRequest > 0) {
            begin(null)
            onSignInRequestConsumed()
        }
    }

    when (phase) {
        HorizonPhase.IDLE -> {
            error?.let {
                Text(it, style = LocalTypography.current.bodySmall, color = LocalColorScheme.current.negative.content)
            }
            UiSetPrimaryButton("Sign in", onClick = { begin(null) })
        }
        HorizonPhase.PROVING -> {
            Text("Signing in…", style = LocalTypography.current.body)
            UiSetSecondaryButton("Cancel", onClick = ::cancel)
        }
        HorizonPhase.CHOICE -> {
            // Said here rather than by choosing silently: a new account and
            // someone else's existing one are different tenants, and only
            // the operator knows which this headset should join.
            Text(
                "This headset isn't linked to an account yet.",
                style = LocalTypography.current.body,
            )
            Text(
                "Creating an account uses this headset's own Meta identity — " +
                    "nothing to approve on your phone.",
                style = LocalTypography.current.bodySmall,
                color = LocalContentColors.current.secondary,
            )
            UiSetPrimaryButton(
                "Create a new account",
                onClick = { begin("create") },
                modifier = Modifier.fillMaxWidth(),
            )
            Text(
                "Already have an account? Join it here — you'll approve the link on your iPhone.",
                style = LocalTypography.current.bodySmall,
                color = LocalContentColors.current.secondary,
            )
            // UiSet labels are plain strings, so the bold brand phrase
            // becomes its own text: a wrapping row that reads as one
            // sentence and taps like the doors elsewhere in Settings.
            Row(
                Modifier
                    .fillMaxWidth()
                    .clickable(onClick = { begin("join_apple") })
                    .padding(vertical = spacing.medium),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                FlowRow(Modifier.weight(1f)) {
                    Text(
                        "Use an existing ",
                        style = LocalTypography.current.body,
                    )
                    Text(
                        "Sign in with Apple",
                        style = LocalTypography.current.body.copy(
                            fontWeight = FontWeight.Bold,
                        ),
                    )
                    Text(
                        " account",
                        style = LocalTypography.current.body,
                    )
                }
                Text(
                    ">",
                    style = LocalTypography.current.body,
                    color = LocalContentColors.current.secondary,
                    modifier = Modifier.padding(start = spacing.small),
                )
            }
            UiSetSecondaryButton("Cancel", onClick = ::cancel)
        }
        HorizonPhase.WAITING -> {
            // A UI Set dialog rather than inline text: it sits centred, where
            // gaze targeting is most reliable, with one large Cancel — Meta's
            // eyes guidance asks for an explicit dismiss, so tapping outside
            // does nothing. The two steps are sending to the phone, then
            // waiting for the approval there.
            val status = when (linkSent) {
                null -> "Sending to your phone…"
                true -> "Approval sent to your Horizon mobile app — tap the notification."
                false -> "Phone request wasn't sent. Enter the code at $verifyUri."
            }
            Text("Waiting for approval…", style = LocalTypography.current.body)
            BasicDialog(
                title = "Approve on your phone",
                description = "$status\n\nCode: $userCode",
                primaryAction = DialogAction(label = "Cancel", onClick = ::cancel),
                onDismissRequest = {},
                progress = DialogProgress(currentStep = if (linkSent == true) 2 else 1, totalSteps = 2),
            )
        }
    }
}
