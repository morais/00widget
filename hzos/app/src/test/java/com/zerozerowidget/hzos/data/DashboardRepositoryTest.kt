package com.zerozerowidget.hzos.data

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * C1 in the hzos audit: refreshes are ordered, and a result that outlives
 * its credential is dropped. The poll loop is never started here; every
 * refresh is a manual [DashboardRepository.refresh], which is exactly the
 * path the credential collector does not cancel.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class DashboardRepositoryTest {
    private class FakeStore(initial: ConnectionStore.Connection) : ConnectionSource {
        val flow = MutableStateFlow(initial)
        override val connection: Flow<ConnectionStore.Connection> = flow
        override suspend fun current() = flow.value
    }

    /** Each fetch waits on the next queued answer, so tests decide the order. */
    private class GatedApi : DashboardApi {
        val answers = ArrayDeque<CompletableDeferred<DashboardResponse>>()
        var fetches = 0
        override suspend fun fetchDashboard(): DashboardResponse {
            fetches++
            return answers.removeFirst().await()
        }
        override suspend fun runAction(actionId: String, cardId: String?) = Unit
        override suspend fun deleteCard(id: String) = Unit
        override suspend fun endActivity(externalActivityId: String) = Unit
    }

    private fun card(id: String) = DashboardCard(id = id, template = DashboardTemplate.SUMMARY, title = id)
    private fun response(vararg ids: String) = DashboardResponse(cards = ids.map(::card))

    private fun TestScope.repo(store: FakeStore, api: GatedApi) = DashboardRepository(
        store = store,
        apiFactory = { _, _ -> api },
        scope = TestScope(StandardTestDispatcher(testScheduler)),
        defaultBaseUrl = "https://example.invalid"
    )

    @Test
    fun laterRefreshWinsEvenWhenTheEarlierAnswersLast() = runTest {
        val store = FakeStore(ConnectionStore.Connection("", "key-a"))
        val api = GatedApi()
        val first = CompletableDeferred<DashboardResponse>().also(api.answers::addLast)
        val second = CompletableDeferred<DashboardResponse>().also(api.answers::addLast)
        val repo = repo(store, api)

        repo.refresh()
        repo.refresh()
        advanceUntilIdle()
        // Serialised: the second fetch has not started while the first waits.
        assertEquals(1, api.fetches)

        second.complete(response("new"))
        first.complete(response("old"))
        advanceUntilIdle()

        assertEquals(2, api.fetches)
        assertEquals(listOf("new"), repo.state.value.cards.map { it.id })
    }

    @Test
    fun refreshInFlightAcrossSignOutDoesNotRepaintTheOldAccount() = runTest {
        val store = FakeStore(ConnectionStore.Connection("", "key-a"))
        val api = GatedApi()
        val answer = CompletableDeferred<DashboardResponse>().also(api.answers::addLast)
        val repo = repo(store, api)

        repo.refresh()
        advanceUntilIdle()
        assertEquals(1, api.fetches)

        // Sign out while the fetch is outstanding.
        store.flow.value = ConnectionStore.Connection("", "")
        repo.clearServerData()
        answer.complete(response("old-account-card"))
        advanceUntilIdle()

        assertTrue(repo.state.value.cards.isEmpty())
        assertFalse(repo.state.value.isConfigured)
    }

    @Test
    fun refreshInFlightAcrossAccountSwitchIsDropped() = runTest {
        // The key changes without clearServerData (a fresh sign-in saved over
        // the old one): the stored-key check alone still fences it off.
        val store = FakeStore(ConnectionStore.Connection("", "key-a"))
        val api = GatedApi()
        val answer = CompletableDeferred<DashboardResponse>().also(api.answers::addLast)
        val repo = repo(store, api)

        repo.refresh()
        advanceUntilIdle()
        store.flow.value = ConnectionStore.Connection("", "key-b")
        answer.complete(response("account-a-card"))
        advanceUntilIdle()

        assertTrue(repo.state.value.cards.isEmpty())
    }

    /** Answers every fetch at once; counts them. */
    private class CountingApi : DashboardApi {
        var fetches = 0
        override suspend fun fetchDashboard(): DashboardResponse {
            fetches++
            // Suspend like a real request, so a collector can observe
            // whatever the repository emitted before the answer.
            yield()
            return DashboardResponse()
        }
        override suspend fun runAction(actionId: String, cardId: String?) = Unit
        override suspend fun deleteCard(id: String) = Unit
        override suspend fun endActivity(externalActivityId: String) = Unit
    }

    @Test
    fun pollsOnlyWhileAPanelIsVisible() = runTest {
        val store = FakeStore(ConnectionStore.Connection("", "key-a"))
        val api = CountingApi()
        val repoScope = TestScope(StandardTestDispatcher(testScheduler))
        val repo = DashboardRepository(store, { _, _ -> api }, repoScope, "https://example.invalid")

        // The poll loop never ends: cancel it however the test ends, or a
        // failed assertion leaves runTest advancing virtual time forever.
        try {
            // Time is advanced explicitly; advanceUntilIdle never returns here.
            repo.setActive(false)
            repo.start()
            runCurrent()
            advanceTimeBy(5 * 60_000L)
            assertEquals("no fetch while every panel is hidden", 0, api.fetches)

            repo.setActive(true)
            runCurrent()
            assertEquals("a returning panel refreshes at once", 1, api.fetches)
            advanceTimeBy(60_000L + 1)
            assertEquals("then polls every minute", 2, api.fetches)

            repo.setActive(false)
            runCurrent()
            advanceTimeBy(5 * 60_000L)
            assertEquals("and stops again when hidden", 2, api.fetches)
        } finally {
            repoScope.cancel()
        }
    }

    @Test
    fun unchangedCardsKeepTheirInstanceSoComposeSkipsThem() {
        val a = card("a")
        val b = card("b")
        val old = listOf(a, b)
        // Equal lists: the old list itself.
        assertTrue(DashboardRepository.reuseUnchanged(old, listOf(card("a"), card("b"))) === old)
        // One changed: the unchanged one is the old instance, the changed one new.
        val changedB = card("b").copy(value = "2")
        val merged = DashboardRepository.reuseUnchanged(old, listOf(card("a"), changedB))
        assertTrue(merged[0] === a)
        assertTrue(merged[1] === changedB)
    }

    @Test
    fun aBackgroundPollEmitsAtMostOnceAndNeverFlickersLoading() = runTest {
        val store = FakeStore(ConnectionStore.Connection("", "key-a"))
        val api = CountingApi()
        val repoScope = TestScope(StandardTestDispatcher(testScheduler))
        val repo = DashboardRepository(store, { _, _ -> api }, repoScope, "https://example.invalid")
        val seen = mutableListOf<DashboardState>()
        val collector = repoScope.launch { repo.state.collect { seen += it } }
        try {
            repo.start()
            runCurrent()
            seen.clear()
            advanceTimeBy(60_000L + 1) // one background poll
            assertEquals("the poll ran", 2, api.fetches)
            // At most the result itself (StateFlow drops it if nothing
            // differs), and never an isLoading flicker before it.
            assertTrue(seen.size <= 1)
            assertTrue(seen.none { it.isLoading })
        } finally {
            collector.cancel()
            repoScope.cancel()
        }
    }
}
