package com.zerozerowidget.hzos.ui.dashboard

import com.zerozerowidget.hzos.data.DashboardCard
import com.zerozerowidget.hzos.data.LiveActivitySession

/**
 * A dashboard item plus the store it came from. [key] is unique across
 * both stores, so a server card that reuses a sample's id can neither
 * crash the LazyColumn with a duplicate key nor expand both rows at once.
 */
internal data class Sourced<T>(val item: T, val isSample: Boolean) {
    val key: String
        get() {
            val id = when (item) {
                is DashboardCard -> item.id
                is LiveActivitySession -> item.externalActivityId
                else -> item.toString()
            }
            return (if (isSample) "sample:" else "server:") + id
        }
}
