package com.zerozerowidget.hzos.ui

import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The relative-time and staleness rules every card and activity shows. */
class UiHelpersTest {
    private val now = Instant.parse("2026-09-28T12:00:00Z")

    @Test
    fun relativeTimeReadsPastAndFuture() {
        assertEquals("5m ago", relativeTime("2026-09-28T11:55:00Z", now))
        assertEquals("in 2h", relativeTime("2026-09-28T14:00:00Z", now))
        assertEquals("3d ago", relativeTime("2026-09-25T12:00:00Z", now))
        assertEquals("just now", relativeTime("2026-09-28T11:59:30Z", now))
    }

    @Test
    fun underAMinuteAheadIsNotJustNow() {
        assertEquals("in <1m", relativeTime("2026-09-28T12:00:40Z", now))
        assertEquals("just now", relativeTime("2026-09-28T12:00:00Z", now))
    }

    @Test
    fun aPastOnlyMomentAheadOfTheClockReadsAsNow() {
        // A sync that landed after the last clock tick, or a server clock
        // running ahead: never "synced in <1m".
        assertEquals("just now", relativeTimeAgo("2026-09-28T12:00:15Z", now))
        assertEquals("just now", relativeTimeAgo("2026-09-28T12:05:00Z", now))
        assertEquals("5m ago", relativeTimeAgo("2026-09-28T11:55:00Z", now))
        assertNull(relativeTimeAgo("yesterday", now))
    }

    @Test
    fun relativeTimeIgnoresWhatItCannotParse() {
        assertNull(relativeTime(null, now))
        assertNull(relativeTime("", now))
        assertNull(relativeTime("yesterday", now))
    }

    @Test
    fun staleAfterWinsOverTheHourFallback() {
        // staleAfter still ahead: fresh, however old updatedAt is.
        assertFalse(isStale("2026-09-28T08:00:00Z", "2026-09-28T13:00:00Z", now))
        assertTrue(isStale("2026-09-28T11:59:00Z", "2026-09-28T11:30:00Z", now))
    }

    @Test
    fun withoutStaleAfterAnHourSinceUpdateIsStale() {
        assertFalse(isStale("2026-09-28T11:30:00Z", null, now))
        assertTrue(isStale("2026-09-28T10:30:00Z", null, now))
    }

    @Test
    fun unparseableDatesNeverMarkACardStale() {
        assertFalse(isStale("garbage", null, now))
        assertFalse(isStale(null, "garbage", now))
        assertFalse(isStale(null, null, now))
    }

    @Test
    fun aSampleIsNeverStale() {
        // Past its staleAfter: stale for a real card, never for a sample.
        assertTrue(showsStale(false, "2026-09-28T11:59:00Z", "2026-09-28T11:30:00Z", now))
        assertFalse(showsStale(true, "2026-09-28T11:59:00Z", "2026-09-28T11:30:00Z", now))
        // Old with no staleAfter: likewise.
        assertFalse(showsStale(true, "2026-09-27T08:00:00Z", null, now))
    }
}
