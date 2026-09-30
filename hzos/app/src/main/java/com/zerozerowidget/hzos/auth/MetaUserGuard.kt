package com.zerozerowidget.hzos.auth

import com.zerozerowidget.hzos.ZeroZeroWidgetApp
import com.zerozerowidget.hzos.data.MetaUserCheck
import com.zerozerowidget.hzos.data.metaUserCheck
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Enforces the stored session's Meta binding. Signed out is
 * [MetaUserCheck.MATCHES]: nothing to check. A different Meta user
 * ([MetaUserCheck.SWITCHED]) or a session with no Meta id at all
 * ([MetaUserCheck.UNBOUND]) clears the session and its cards, so the next
 * sign-in binds it to whoever is wearing the headset. An unreadable current
 * user is
 * [MetaUserCheck.UNKNOWN]: the session is kept, and the caller holds its
 * data back until a later check can tell (see ZeroZeroWidgetApp).
 */
suspend fun checkMetaUser(app: ZeroZeroWidgetApp): MetaUserCheck {
    val stored = app.connectionStore.current()
    if (stored.apiKey.isBlank()) return MetaUserCheck.MATCHES
    // Bounded: polling waits on this answer, and a Platform SDK call that
    // never returns must read as unknown (retried), not stall the dashboard.
    val current = withTimeoutOrNull(META_USER_READ_TIMEOUT_MS) { app.horizonAuth.loggedInUserId() }
    val check = metaUserCheck(stored.metaUserId, current)
    if (check == MetaUserCheck.SWITCHED || check == MetaUserCheck.UNBOUND) {
        app.connectionStore.clear()
        // Drop the previous user's cards now, and fence off any refresh
        // still in flight for them (see DashboardRepository).
        app.repository.clearServerData()
    }
    return check
}

private const val META_USER_READ_TIMEOUT_MS = 5_000L
