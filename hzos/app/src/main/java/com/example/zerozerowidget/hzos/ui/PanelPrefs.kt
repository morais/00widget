package com.example.zerozerowidget.hzos.ui

import android.content.Context
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.floatPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

private val Context.panelPrefsStore by preferencesDataStore(name = "panel_prefs")

/**
 * Look, not data: whether shell panels render transparent (passthrough shows
 * through the window) or opaque black. Separate DataStore from
 * ConnectionStore on purpose — wiping credentials must never wipe this, and
 * vice versa.
 */
class PanelPrefs(private val context: Context) {
    companion object {
        private val TRANSPARENT = booleanPreferencesKey("transparent_panels")
        private val CARD_ALPHA = floatPreferencesKey("card_alpha")
        private val HIDE_INDICATORS = booleanPreferencesKey("hide_sample_indicators")
        /** Cards nearly solid by default — just a breath of passthrough. */
        const val DEFAULT_CARD_ALPHA = 0.85f
    }

    /** Transparent windows by default; opaque is the opt-in. */
    val transparent: Flow<Boolean> =
        context.panelPrefsStore.data.map { it[TRANSPARENT] != false }

    /** Card surface opacity, 0.5 (glassy) to 1.0 (solid). */
    val cardAlpha: Flow<Float> =
        context.panelPrefsStore.data.map {
            (it[CARD_ALPHA] ?: DEFAULT_CARD_ALPHA).coerceIn(0.5f, 1f)
        }

    /**
     * Hides SAMPLE badges and the sample notice, mirroring iOS
     * hideSampleIndicators. The demo data itself stays — this only removes
     * the labels, e.g. for screenshots and recordings.
     */
    val hideSampleIndicators: Flow<Boolean> =
        context.panelPrefsStore.data.map { it[HIDE_INDICATORS] == true }

    suspend fun setTransparent(value: Boolean) {
        context.panelPrefsStore.edit { it[TRANSPARENT] = value }
    }

    suspend fun setCardAlpha(value: Float) {
        context.panelPrefsStore.edit { it[CARD_ALPHA] = value.coerceIn(0.5f, 1f) }
    }

    suspend fun setHideSampleIndicators(value: Boolean) {
        context.panelPrefsStore.edit { it[HIDE_INDICATORS] = value }
    }
}

/** Read by SampleBadge/SampleNoticeBanner; provided at each panel root. */
val LocalHideSampleIndicators =
    androidx.compose.runtime.compositionLocalOf { false }
