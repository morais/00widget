package com.zerozerowidget.hzos.ui.dashboard

import com.zerozerowidget.hzos.data.DashboardCard
import com.zerozerowidget.hzos.data.DashboardTemplate
import com.zerozerowidget.hzos.data.LiveActivitySession
import com.zerozerowidget.hzos.data.SampleData
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class SourcedTest {
    private fun card(id: String) = DashboardCard(id = id, template = DashboardTemplate.SUMMARY, title = id)

    @Test
    fun serverCardReusingASampleIdGetsItsOwnKey() {
        // The Worker accepts any id, so a producer can publish one a sample
        // already uses. Both render at once; LazyColumn needs distinct keys.
        val id = SampleData.makeCards().first().id
        val server = Sourced(card(id), isSample = false)
        val sample = Sourced(card(id), isSample = true)
        assertNotEquals(server.key, sample.key)
    }

    @Test
    fun serverCardWithSamplePrefixIsNotASample() {
        // Origin, not the id, decides: a published `sample-…` card is a
        // server card, deletable and actionable like any other.
        assertEquals(false, Sourced(card("sample-anything"), isSample = false).isSample)
    }

    @Test
    fun activitiesKeyByExternalId() {
        val session = LiveActivitySession(externalActivityId = "build-42", title = "Build")
        assertEquals("server:build-42", Sourced(session, isSample = false).key)
        assertEquals("sample:build-42", Sourced(session, isSample = true).key)
    }
}
