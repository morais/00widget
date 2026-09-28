package com.zerozerowidget.hzos.ui.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
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
import androidx.compose.ui.unit.dp
import com.zerozerowidget.hzos.BuildConfig
import com.zerozerowidget.hzos.ZeroZeroWidgetApp
import com.zerozerowidget.hzos.data.SubscriptionState
import com.zerozerowidget.hzos.data.ZeroWidgetApi
import com.zerozerowidget.hzos.ui.PanelPrefs
import com.zerozerowidget.hzos.ui.cardAlphaState
import com.zerozerowidget.hzos.ui.cards.GlassCard
import com.zerozerowidget.hzos.ui.theme.spacing
import com.zerozerowidget.hzos.ui.uiset.UiSetPrimaryButton
import com.zerozerowidget.hzos.ui.uiset.UiSetSecondaryButton
import kotlinx.coroutines.launch
import metavrx.uiset.compose.Text
import metavrx.uiset.compose.theme.LocalColorScheme
import metavrx.uiset.compose.theme.LocalContentColors
import metavrx.uiset.compose.theme.LocalTypography

/**
 * Meta subscription purchase + status. Shown from Settings when signed in
 * with `SUBSCRIPTIONS_ENABLED` (BuildConfig, off unless the deployment
 * sells anything) — ordinary builds never compile this in... rather, never
 * reach it: the flag is a build-time constant, so the branch folds away.
 *
 * Flow per tier: system checkout → confirm ownership → sync the purchase to
 * the Worker (`POST /v1/meta/subscription/sync`, which verifies via Meta
 * S2S) → reread the merged entitlement. The server stays the source of
 * truth throughout; owning a SKU locally never grants anything by itself.
 */
@Composable
fun SubscriptionSection(app: ZeroZeroWidgetApp) {
    val scope = rememberCoroutineScope()
    val cardAlpha by app.panelPrefs.cardAlphaState()
    val monthlySku = BuildConfig.SUBSCRIPTION_MONTHLY_SKU
    val yearlySku = BuildConfig.SUBSCRIPTION_YEARLY_SKU
    val tiers = listOf("Monthly" to monthlySku, "Yearly" to yearlySku)
        .filter { it.second.isNotBlank() }

    var status by remember { mutableStateOf<SubscriptionState?>(null) }
    var statusLoaded by remember { mutableStateOf(false) }
    var prices by remember { mutableStateOf(mapOf<String, String>()) }
    var busySku by remember { mutableStateOf<String?>(null) }
    var restoring by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    suspend fun api(): ZeroWidgetApi? = app.authedApi()

    suspend fun refreshStatus() {
        status = try {
            api()?.fetchSubscription()
        } catch (e: Exception) {
            null
        }
        statusLoaded = true
    }

    LaunchedEffect(Unit) {
        refreshStatus()
        if (app.horizonIap.isAvailable && tiers.isNotEmpty()) {
            prices = app.horizonIap.fetchProducts(tiers.map { it.second })
                .associate { it.sku to it.formattedPrice }
        }
    }

    fun buy(sku: String) {
        if (busySku != null || restoring) return
        busySku = sku
        error = null
        scope.launch {
            try {
                val purchased = app.horizonIap.checkout(sku).getOrElse { throw it }
                val userId = app.horizonAuth.loggedInUserId()
                    ?: throw IllegalStateException(
                        "Signed into Meta, but the account id is unreadable."
                    )
                try {
                    status = api()?.syncMetaSubscription(userId, purchased)
                    statusLoaded = true
                } catch (e: ZeroWidgetApi.ApiException) {
                    throw if (e.status == 404) {
                        IllegalStateException(
                            "Purchase done — now update the Worker so it can record it."
                        )
                    } else {
                        e
                    }
                }
                refreshStatus()
            } catch (e: Exception) {
                error = (e.message ?: e.javaClass.simpleName).take(200)
            } finally {
                busySku = null
            }
        }
    }

    fun restore() {
        if (busySku != null || restoring) return
        restoring = true
        error = null
        scope.launch {
            try {
                val userId = app.horizonAuth.loggedInUserId()
                    ?: throw IllegalStateException(
                        "Signed into Meta, but the account id is unreadable."
                    )
                val owned = app.horizonIap.ownedSkus()
                if (owned.isEmpty()) {
                    throw IllegalStateException(
                        "No Meta purchases found for this account."
                    )
                }
                val client = api() ?: throw IllegalStateException("Not connected.")
                var last: SubscriptionState? = null
                for (sku in owned) {
                    last = client.syncMetaSubscription(userId, sku)
                }
                status = last
                statusLoaded = true
                refreshStatus()
            } catch (e: Exception) {
                error = (e.message ?: e.javaClass.simpleName).take(200)
            } finally {
                restoring = false
            }
        }
    }

    GlassCard(cardAlpha = cardAlpha) {
        Column(verticalArrangement = Arrangement.spacedBy(spacing.small)) {
            Text("Subscription", style = LocalTypography.current.title)
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "Status",
                    style = LocalTypography.current.body,
                    modifier = Modifier.weight(1f)
                )
                if (!statusLoaded) {
                    Text(
                        "Loading…",
                        style = LocalTypography.current.bodySmall,
                        color = LocalContentColors.current.secondary
                    )
                } else {
                    Text(
                        status?.displayLabel ?: "Unknown",
                        style = LocalTypography.current.bodySmall,
                        color = if (status?.needsAttention == true) {
                            LocalColorScheme.current.negative.content
                        } else {
                            LocalContentColors.current.secondary
                        }
                    )
                }
            }

            if (status?.active == true) {
                Text(
                    "Manage or cancel in the Meta Horizon mobile app.",
                    style = LocalTypography.current.bodySmall,
                    color = LocalContentColors.current.secondary
                )
            } else {
                if (!app.horizonIap.isAvailable) {
                    Text(
                        "Subscriptions need a Horizon Platform app ID " +
                            "(`platformAppId` in hzos/local.properties).",
                        style = LocalTypography.current.bodySmall,
                        color = LocalContentColors.current.secondary
                    )
                } else if (tiers.isEmpty()) {
                    Text(
                        "No subscription products configured on this build.",
                        style = LocalTypography.current.bodySmall,
                        color = LocalContentColors.current.secondary
                    )
                } else {
                    tiers.forEach { (label, sku) ->
                        val price = prices[sku]
                        UiSetPrimaryButton(
                            if (busySku == sku) {
                                "Processing…"
                            } else if (price != null) {
                                "$label — $price"
                            } else {
                                label
                            },
                            onClick = { buy(sku) },
                            enabled = busySku == null && !restoring,
                            modifier = Modifier.fillMaxWidth()
                        )
                    }
                    Spacer(Modifier.height(2.dp))
                    UiSetSecondaryButton(
                        if (restoring) "Restoring…" else "Restore purchases",
                        onClick = ::restore,
                        enabled = busySku == null && !restoring,
                        modifier = Modifier.fillMaxWidth()
                    )
                }
            }

            error?.let {
                Text(
                    it,
                    style = LocalTypography.current.bodySmall,
                    color = LocalColorScheme.current.negative.content
                )
            }
        }
    }
}
