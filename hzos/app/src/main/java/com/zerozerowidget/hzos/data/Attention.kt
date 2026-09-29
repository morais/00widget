package com.zerozerowidget.hzos.data

// When a card or activity asks a person to act: the "Needs you" rule,
// ported from ios/Sources/Shared/Models/DashboardStatus.swift. Keep the two
// in lockstep.

/**
 * Statuses that ask for a look. `unknown` counts: it is what an unrecognised
 * status from a newer server decodes to, so the app cannot vouch for it.
 */
val DashboardStatus.needsAttention: Boolean
    get() = when (this) {
        DashboardStatus.WARNING,
        DashboardStatus.CRITICAL,
        DashboardStatus.OFFLINE,
        DashboardStatus.PAUSED,
        DashboardStatus.UNKNOWN -> true

        DashboardStatus.GOOD,
        DashboardStatus.FINISHED,
        DashboardStatus.RUNNING -> false
    }

/**
 * A card only says "Needs you" when it has both an attention status and an
 * action to take: a warning without a button is an observation, not a
 * hand-off.
 */
val DashboardCard.needsUserAttention: Boolean
    get() = status.needsAttention && !actions.isNullOrEmpty()

/**
 * A warning row is the activity's explicit hand-off to its operator. Other
 * warning-like states can mean degraded machinery rather than a human
 * decision, so they do not become "Needs you".
 */
val LiveActivitySession.needsUserAttention: Boolean
    get() = items.orEmpty().any { it.status == DashboardStatus.WARNING }
