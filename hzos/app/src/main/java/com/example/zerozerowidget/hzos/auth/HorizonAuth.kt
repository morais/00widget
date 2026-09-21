package com.example.zerozerowidget.hzos.auth

import android.content.Context
import android.content.Intent
import android.util.Log
import horizon.core.android.driver.coroutines.HorizonServiceConnection
import horizon.platform.users.Users
import kotlinx.coroutines.CoroutineScope

/**
 * Thin wrapper over the Horizon Platform SDK Login API (`send_auth_url`).
 *
 * This is the *delivery* half of login only: it pushes our verification URL
 * to the Meta Horizon mobile app so the operator approves there instead of
 * retyping a code. Code issuance, approval, and token minting are the
 * Worker's device flow — see `data/DeviceAuth.kt`.
 *
 * Inactive until a Platform app ID is configured (`platformAppId` in
 * hzos/local.properties → BuildConfig). With none, [isAvailable] is false
 * and the UI offers manual paste only.
 */
class HorizonAuth(
    context: Context,
    private val scope: CoroutineScope,
    val appId: String,
) {
    private val appContext: Context = context.applicationContext

    val isAvailable: Boolean get() = appId.isNotBlank()

    fun connect() {
        if (!isAvailable) return
        try {
            HorizonServiceConnection.connect(appId, appContext, scope)
        } catch (_: Exception) {
            // Platform service absent (non-Quest device, old OS): stay
            // unavailable; the UI falls back to the manual code display.
        }
    }

    /**
     * Builds the OS confirmation Intent for [authUrl]. Null when the
     * Platform SDK isn't initialized — the caller then shows the code + URL
     * for manual entry (the required fallback for older OS versions).
     */
    suspend fun buildSendIntent(authUrl: String): Intent? {
        if (!isAvailable) return null
        return try {
            // No-arg Users resolves the shared connection established by
            // connect(); the explicit-connection constructor is
            // SDK-internal. Throws when init hasn't completed — caught below
            // so the UI can fall back to the manual code display.
            Users().sendAuthUrl(authUrl)
        } catch (e: Exception) {
            Log.e(TAG, "sendAuthUrl failed: ${e.javaClass.simpleName}: ${e.message}")
            null
        }
    }

    companion object {
        private const val TAG = "HorizonAuth"
    }
}
