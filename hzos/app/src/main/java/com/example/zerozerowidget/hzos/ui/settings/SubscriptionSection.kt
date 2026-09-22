package com.example.zerozerowidget.hzos.ui.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.Button
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.example.zerozerowidget.hzos.ZeroZeroWidgetApp
import com.example.zerozerowidget.hzos.data.SubscriptionState
import com.example.zerozerowidget.hzos.data.ZeroWidgetApi
import com.example.zerozerowidget.hzos.ui.cards.GlassCard
import kotlinx.coroutines.launch

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
    val monthlySku = com.example.zerozerowidget.hzos.BuildConfig.SUBSCRIPTION_MONTHLY_SKU
    val yearlySku = com.example.zerozerowidget.hzos.BuildConfig.SUBSCRIPTION_YEARLY_SKU
    val tiers = listOf("Monthly" to monthlySku, "Yearly" to yearlySku)
        .filter { it.second.isNotBlank() }

    var status by remember { mutableStateOf<SubscriptionState?>(null) }
    var statusLoaded by remember { mutableStateOf(false) }
    var prices by remember { mutableStateOf(mapOf<String, String>()) }
    var busySku by remember { mutableStateOf<String?>(null) }
    var restoring by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    suspend fun api(): ZeroWidgetApi? {
        val current = app.connectionStore.current()
        val base = current.baseUrl.ifBlank {
            com.example.zerozerowidget.hzos.BuildConfig.DEFAULT_BASE_URL
        }
        if (current.apiKey.isBlank() || base.isBlank()) return null
        return ZeroWidgetApi(app.http, base, current.apiKey)
    }

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
                    ?: throw IllegalStateException("Signed into Meta, but the account id is unreadable.")
                try {
                    status = api()?.syncMetaSubscription(userId, purchased)
                    statusLoaded = true
                } catch (e: ZeroWidgetApi.ApiException) {
                    throw if (e.status == 404) {
                        IllegalStateException("Purchase done — now update the Worker so it can record it.")
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
                    ?: throw IllegalStateException("Signed into Meta, but the account id is unreadable.")
                val owned = app.horizonIap.ownedSkus()
                if (owned.isEmpty()) throw IllegalStateException("No Meta purchases found for this account.")
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

    GlassCard(cardAlpha = 1f) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Subscription", style = MaterialTheme.typography.titleSmall)
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "Status",
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.weight(1f),
                )
                if (!statusLoaded) {
                    Text(
                        "Loading…",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                } else {
                    Text(
                        status?.displayLabel ?: "Unknown",
                        style = MaterialTheme.typography.bodySmall,
                        color = if (status?.needsAttention == true) {
                            MaterialTheme.colorScheme.error
                        } else {
                            MaterialTheme.colorScheme.onSurfaceVariant
                        },
                    )
                }
            }

            if (status?.active == true) {
                Text(
                    "Manage or cancel in the Meta Horizon mobile app.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            } else {
                if (!app.horizonIap.isAvailable) {
                    Text(
                        "Subscriptions need a Horizon Platform app ID " +
                            "(`platformAppId` in hzos/local.properties).",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                } else if (tiers.isEmpty()) {
                    Text(
                        "No subscription products configured on this build.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                } else {
                    tiers.forEach { (label, sku) ->
                        val price = prices[sku]
                        Button(
                            onClick = { buy(sku) },
                            enabled = busySku == null && !restoring,
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Text(
                                if (busySku == sku) "Processing…"
                                else if (price != null) "$label — $price"
                                else label,
                            )
                        }
                    }
                    Spacer(Modifier.height(2.dp))
                    FilledTonalButton(
                        onClick = ::restore,
                        enabled = busySku == null && !restoring,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text(if (restoring) "Restoring…" else "Restore purchases")
                    }
                }
            }

            error?.let {
                Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
            }
        }
    }
}
