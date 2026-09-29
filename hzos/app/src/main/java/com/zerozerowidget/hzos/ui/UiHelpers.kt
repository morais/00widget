package com.zerozerowidget.hzos.ui

import android.content.Context
import android.content.Intent
import android.net.Uri
import com.zerozerowidget.hzos.data.ZeroWidgetApi
import java.time.Duration
import java.time.Instant

/** Opens an https deep link in the headset browser. Returns false when refused. */
fun openDeepLink(context: Context, raw: String?): Boolean {
    if (raw.isNullOrBlank()) return false
    return try {
        val uri = Uri.parse(raw)
        if (uri.scheme?.lowercase() != "https") return false
        context.startActivity(
            Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
        true
    } catch (_: Exception) {
        false
    }
}

/** Short relative time ("3m ago", "in 2d"). Static text — recompute on refresh. */
fun relativeTime(iso: String?, now: Instant = Instant.now()): String? {
    if (iso.isNullOrBlank()) return null
    return try {
        val then = Instant.parse(iso)
        val d = Duration.between(now, then)
        val abs = d.abs()
        val text = when {
            abs.toMinutes() < 1 -> "<1m"
            abs.toHours() < 1 -> "${abs.toMinutes()}m"
            abs.toDays() < 1 -> "${abs.toHours()}h"
            else -> "${abs.toDays()}d"
        }
        // Under a minute ago is "just now"; under a minute ahead is not —
        // "Ends just now" read as over for something 40 seconds away.
        when {
            !d.isNegative && !d.isZero -> "in $text"
            text == "<1m" -> "just now"
            else -> "$text ago"
        }
    } catch (_: Exception) {
        null
    }
}

/**
 * [relativeTime] for moments that can only be past (a sync, a last use).
 * Such a moment can still sit a little ahead of [now]: the ticking clock
 * lags the sync that just landed by up to one tick, and a server clock can
 * run ahead of the headset's. Either read as "synced in <1m", so a future
 * moment counts as now.
 */
fun relativeTimeAgo(iso: String?, now: Instant = Instant.now()): String? {
    val then = try {
        Instant.parse(iso)
    } catch (_: Exception) {
        null
    }
    return then?.let { relativeTime(minOf(it, now).toString(), now) }
}

/** True when the card should read as stale (mirrors DashboardCard.isStale). */
fun isStale(updatedAt: String?, staleAfter: String?, now: Instant = Instant.now()): Boolean {
    try {
        staleAfter?.let { return now >= Instant.parse(it) }
        updatedAt?.let { return Duration.between(Instant.parse(it), now).toSeconds() > 3600 }
    } catch (_: Exception) {
        // Unparseable dates never mark a card stale on their own.
    }
    return false
}

/**
 * Honest delete/end failure text. Current Horizon credentials can publish;
 * a 403 usually means an older credential survived the server upgrade.
 */
fun describeDeleteError(e: Throwable): String {
    val api = e as? ZeroWidgetApi.ApiException
    if (api?.status == 401) {
        return "This sign-in has expired. Sign in again, then retry."
    }
    if (api?.status == 403) {
        return "This sign-in predates Horizon content management. " +
            "Sign out and sign in again, then retry."
    }
    return (e.message ?: e.javaClass.simpleName).take(200)
}

/**
 * Honest action-run failure text. The usual case is a sleeping producer:
 * the server tried the webhook three times and heard nothing back, which
 * arrives as a 502 with a JSON body — shown raw it reads as the button
 * doing nothing at all. Name the cause instead.
 */
fun describeRunError(e: Throwable): String {
    val api = e as? ZeroWidgetApi.ApiException
        ?: return (e.message ?: e.javaClass.simpleName).take(200)
    return when (api.status) {
        401 -> "Not signed in — sign in again in Settings."

        402 -> "Publishing needs an active subscription."

        403 -> "This action needs confirming in the app."

        404 -> "That action is gone — refresh and try again."

        409 -> "This action has nowhere to run yet."

        429 -> "Rate limited — try again shortly."

        502 -> "The producer didn't answer — it may be offline. Try again in a bit."

        // The message is already the server's `error` string or "HTTP n".
        else -> api.message ?: "Request failed (${api.status})."
    }
}
