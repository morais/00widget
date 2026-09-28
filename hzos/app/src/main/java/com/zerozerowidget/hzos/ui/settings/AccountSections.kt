package com.zerozerowidget.hzos.ui.settings

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
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
import com.zerozerowidget.hzos.ZeroZeroWidgetApp
import com.zerozerowidget.hzos.data.AccountIdAction
import com.zerozerowidget.hzos.data.SubscriptionState
import com.zerozerowidget.hzos.data.ZeroWidgetApi
import com.zerozerowidget.hzos.data.accountIdAction
import com.zerozerowidget.hzos.ui.PanelPrefs
import com.zerozerowidget.hzos.ui.cards.GlassCard
import com.zerozerowidget.hzos.ui.theme.spacing
import com.zerozerowidget.hzos.ui.uiset.UiSetConfirmDialog
import com.zerozerowidget.hzos.ui.uiset.UiSetDestructiveButton
import com.zerozerowidget.hzos.ui.uiset.UiSetSecondaryButton
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import metavrx.uiset.compose.Text
import metavrx.uiset.compose.theme.LocalColorScheme
import metavrx.uiset.compose.theme.LocalContentColors
import metavrx.uiset.compose.theme.LocalTypography

/**
 * Device sign-out plus delete-or-unlink, grouped like iOS Account and
 * access: the things that end or move a session live together, one tap
 * past the Server rows.
 */
@Composable
internal fun AccountAccessDestination(app: ZeroZeroWidgetApp, onSignedOut: () -> Unit) {
    val scope = rememberCoroutineScope()
    val cardAlpha by app.panelPrefs.cardAlpha.collectAsState(
        initial = PanelPrefs.DEFAULT_CARD_ALPHA
    )

    Column(verticalArrangement = Arrangement.spacedBy(spacing.medium)) {
        GlassCard(cardAlpha = cardAlpha) {
            Column(verticalArrangement = Arrangement.spacedBy(spacing.small)) {
                Text("This device", style = LocalTypography.current.title)
                Text(
                    "Signing out forgets this device's credential and clears " +
                        "its cards straight away.",
                    style = LocalTypography.current.bodySmall,
                    color = LocalContentColors.current.secondary
                )
                UiSetSecondaryButton(
                    "Sign out",
                    onClick = {
                        scope.launch {
                            app.connectionStore.clear()
                            app.repository.clearServerData()
                        }
                    }
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
internal fun AccountSection(
    app: ZeroZeroWidgetApp,
    onOpenSubscription: (() -> Unit)? = null,
    onOpenAccountAccess: () -> Unit
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
            verticalAlignment = Alignment.CenterVertically
        ) {
            if (loaded && accountName.isNullOrBlank()) {
                Text(
                    "Signed in.",
                    style = LocalTypography.current.body,
                    modifier = Modifier.weight(1f)
                )
            } else {
                Text(
                    "Signed in as",
                    style = LocalTypography.current.body,
                    modifier = Modifier.weight(1f)
                )
                Text(
                    if (!loaded) "Loading…" else accountName!!,
                    style = LocalTypography.current.bodySmall,
                    color = LocalContentColors.current.secondary
                )
            }
        }
        if (!subscriptionAnswered) {
            // Reserved while the parallel fetch answers: without it the
            // Account door jumps when this row arrives or stays away.
            Row(
                Modifier.fillMaxWidth().padding(vertical = spacing.medium),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    "Subscription",
                    style = LocalTypography.current.body,
                    modifier = Modifier.weight(1f)
                )
                Text(
                    "Loading…",
                    style = LocalTypography.current.bodySmall,
                    color = LocalContentColors.current.secondary
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
                    modifier = Modifier.weight(1f)
                )
                Text(
                    subscription!!.displayLabel,
                    style = LocalTypography.current.bodySmall,
                    color = if (subscription!!.needsAttention) {
                        LocalColorScheme.current.negative.content
                    } else {
                        LocalContentColors.current.secondary
                    }
                )
                if (onOpenSubscription != null) {
                    Text(
                        ">",
                        style = LocalTypography.current.body,
                        color = LocalContentColors.current.secondary,
                        modifier = Modifier.padding(start = spacing.small)
                    )
                }
            }
        }
        Row(
            Modifier
                .fillMaxWidth()
                .clickable(onClick = onOpenAccountAccess)
                .padding(vertical = spacing.medium),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                "Account and access",
                style = LocalTypography.current.body,
                modifier = Modifier.weight(1f)
            )
            Text(
                ">",
                style = LocalTypography.current.body,
                color = LocalContentColors.current.secondary
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
internal fun AccountAccessSection(
    app: ZeroZeroWidgetApp,
    cardAlpha: Float,
    onSignedOut: () -> Unit
) {
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
                color = LocalContentColors.current.secondary
            )
        }
        return
    }
    if (action == AccountIdAction.NONE) return

    suspend fun api(): ZeroWidgetApi = app.authedApi() ?: throw IllegalStateException("Not connected.")

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
                            "Horizon is the only way into this account — delete it instead."
                        )
                    } else {
                        val serverError = """"error"\s*:\s*"([^"]*)""""
                            .toRegex().find(body)?.groupValues?.getOrNull(1)
                        throw IllegalStateException(
                            serverError?.takeIf { it.isNotBlank() } ?: "Request failed ($status)."
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
                color = LocalContentColors.current.secondary
            )
            error?.let {
                Text(
                    it,
                    style = LocalTypography.current.bodySmall,
                    color = LocalColorScheme.current.negative.content
                )
            }
            if (isDelete) {
                UiSetDestructiveButton(
                    if (busy) "Working…" else "Delete account",
                    onClick = { confirming = action },
                    enabled = !busy
                )
            } else {
                UiSetSecondaryButton(
                    if (busy) "Working…" else "Unlink this headset",
                    onClick = { confirming = action },
                    enabled = !busy
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
            confirmEnabled = !busy
        )
    }
}
