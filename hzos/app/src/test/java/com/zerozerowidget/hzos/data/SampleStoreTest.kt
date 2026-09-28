package com.zerozerowidget.hzos.data

import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * The on-device sample deck: generate, remove one, clear, and survive a
 * restart. Robolectric supplies the Context DataStore needs. The disk-load
 * race in audit C6 is not covered here; it belongs with that fix.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class SampleStoreTest {
    private val context = ApplicationProvider.getApplicationContext<android.content.Context>()

    /** Writes land on a background dispatcher; wait for them, bounded. */
    private fun eventually(check: () -> Boolean) {
        val deadline = System.currentTimeMillis() + 5_000
        while (!check()) {
            check(System.currentTimeMillis() < deadline) { "timed out" }
            Thread.sleep(20)
        }
    }

    private fun loadedStore(): SampleStore {
        val store = SampleStore(context)
        Thread.sleep(200) // let the initial disk read land (see C6)
        return store
    }

    @Test
    fun generatingFillsCardsAndTheDemoActivity() {
        val store = loadedStore()
        store.generateCards()
        assertEquals(SampleData.makeCards().map { it.id }, store.cards.value.map { it.id })
        assertEquals(1, store.activities.value.size)
    }

    @Test
    fun removeAndClearAreLocal() {
        val store = loadedStore()
        store.generateCards()
        val first = store.cards.value.first().id
        store.removeCard(first)
        assertTrue(store.cards.value.none { it.id == first })
        store.clearSamples()
        assertTrue(store.cards.value.isEmpty())
        assertTrue(store.activities.value.isEmpty())
    }

    @Test
    fun theDeckSurvivesARestart() {
        loadedStore().generateCards()
        val expected = SampleData.makeCards().map { it.id }
        // A second store is what a relaunched process builds.
        eventually { SampleStore(context).also { Thread.sleep(100) }.cards.value.map { it.id } == expected }
    }
}
