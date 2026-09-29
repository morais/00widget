package com.zerozerowidget.hzos.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AttentionTest {
    private val action = ActionDefinition(id = "approve", label = "Approve")

    private fun card(status: DashboardStatus, actions: List<ActionDefinition>? = listOf(action)) = DashboardCard(id = "c", title = "Card", status = status, actions = actions)

    private fun activity(vararg statuses: DashboardStatus) = LiveActivitySession(
        externalActivityId = "a",
        title = "Activity",
        items = statuses.mapIndexed { i, s -> LiveActivityItem(id = "$i", title = "Row $i", status = s) }
    )

    @Test
    fun attentionStatusesMatchIos() {
        val attention = DashboardStatus.values().filter { it.needsAttention }.toSet()
        assertEquals(
            setOf(
                DashboardStatus.WARNING,
                DashboardStatus.CRITICAL,
                DashboardStatus.OFFLINE,
                DashboardStatus.PAUSED,
                DashboardStatus.UNKNOWN
            ),
            attention
        )
    }

    @Test
    fun aCardNeedsYouOnlyWithSomethingToPress() {
        assertTrue(card(DashboardStatus.WARNING).needsUserAttention)
        assertFalse("an observation, not a hand-off", card(DashboardStatus.WARNING, actions = null).needsUserAttention)
        assertFalse(card(DashboardStatus.WARNING, actions = emptyList()).needsUserAttention)
        assertFalse("healthy, even with a button", card(DashboardStatus.GOOD).needsUserAttention)
    }

    @Test
    fun anActivityNeedsYouOnlyForAWarningRow() {
        assertTrue(activity(DashboardStatus.GOOD, DashboardStatus.WARNING).needsUserAttention)
        assertFalse("critical is machinery, not a decision", activity(DashboardStatus.CRITICAL).needsUserAttention)
        assertFalse(activity().needsUserAttention)
    }
}
