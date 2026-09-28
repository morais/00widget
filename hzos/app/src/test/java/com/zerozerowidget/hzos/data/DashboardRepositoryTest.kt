package com.zerozerowidget.hzos.data

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
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
        defaultBaseUrl = "https://example.invalid",
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
}
