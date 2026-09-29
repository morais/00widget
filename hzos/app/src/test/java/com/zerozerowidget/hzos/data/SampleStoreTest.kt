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
 * restart, and the disk-load race (audit C6): a change made before the
 * initial load lands must not be undone by it. Robolectric supplies the
 * Context DataStore needs.
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

    private fun loadedStore(): SampleStore = SampleStore(context)

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

    @Test
    fun aClearBeforeTheInitialLoadIsNotUndoneByIt() {
        loadedStore().generateCards()
        eventually { SampleStore(context).also { Thread.sleep(100) }.cards.value.isNotEmpty() }
        // A fresh store, cleared at once — before its disk read can land.
        val store = SampleStore(context)
        store.clearSamples()
        Thread.sleep(300)
        assertTrue(store.cards.value.isEmpty())
    }

    @Test
    fun aGenerateBeforeTheInitialLoadSticks() {
        loadedStore().clearSamples()
        Thread.sleep(200)
        val store = SampleStore(context)
        store.generateCards()
        Thread.sleep(300)
        assertEquals(SampleData.makeCards().size, store.cards.value.size)
    }
}
