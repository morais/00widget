package com.example.zerozerowidget.hzos.ui

import android.content.Context
import android.content.Intent
import android.net.Uri
import java.time.Duration
import java.time.Instant

/** Opens an https deep link in the headset browser. Returns false when refused. */
fun openDeepLink(context: Context, raw: String?): Boolean {
    if (raw.isNullOrBlank()) return false
    return try {
        val uri = Uri.parse(raw)
        if (uri.scheme?.lowercase() != "https") return false
        context.startActivity(Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
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
            abs.toMinutes() < 1 -> "just now"
            abs.toHours() < 1 -> "${abs.toMinutes()}m"
            abs.toDays() < 1 -> "${abs.toHours()}h"
            else -> "${abs.toDays()}d"
        }
        if (text == "just now") text else if (d.isNegative) "$text ago" else "in $text"
    } catch (_: Exception) {
        null
    }
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
