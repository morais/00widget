package com.zerozerowidget.hzos.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import java.time.Instant
import kotlinx.coroutines.delay

/**
 * "Now", as panels display it. relativeTime and isStale read this rather
 * than the wall clock, so "synced 2m ago", "Ends in 5m" and the stale flag
 * move on their own instead of only when a poll happens to redraw them —
 * the same trap the tvOS TVTickingClock exists for (audit C4). Only the
 * composables that read it recompose on a tick.
 *
 * Unprovided (previews, tests) it is simply the time of first read.
 */
val LocalNow = compositionLocalOf { Instant.now() }

/**
 * Relative times are shown to the minute ("just now", "5m"), so a 20s tick
 * keeps them honest without redrawing for nothing.
 */
private const val TICK_MS = 20_000L

/** Provides a ticking [LocalNow] while the panel is started, and no ticks while it is not. */
@Composable
fun ProvideTickingNow(content: @Composable () -> Unit) {
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val now by produceState(Instant.now(), lifecycle) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) {
                value = Instant.now()
                delay(TICK_MS)
            }
        }
    }
    CompositionLocalProvider(LocalNow provides now, content = content)
}
