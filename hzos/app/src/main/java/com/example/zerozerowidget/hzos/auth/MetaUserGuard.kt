package com.example.zerozerowidget.hzos.auth

import com.example.zerozerowidget.hzos.ZeroZeroWidgetApp
import com.example.zerozerowidget.hzos.data.isMetaUserSwitch

/**
 * Enforces the stored session's Meta binding. True when the session still
 * belongs to whoever is wearing the headset — signed out, legacy token
 * without a Meta id, or unreadable current user all count as "nothing to
 * check". False only after clearing a token whose Meta id is present and
 * different, i.e. a real account switch demanding a fresh sign-in.
 */
suspend fun ensureMetaUserMatches(app: ZeroZeroWidgetApp): Boolean {
    val stored = app.connectionStore.current()
    if (stored.apiKey.isBlank() || stored.metaUserId.isBlank()) return true
    if (!isMetaUserSwitch(stored.metaUserId, app.horizonAuth.loggedInUserId())) return true
    app.connectionStore.clear()
    return false
}
