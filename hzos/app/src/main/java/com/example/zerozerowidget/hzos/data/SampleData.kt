package com.example.zerozerowidget.hzos.data

import java.time.Instant

/** Reserved id namespace: demo data the UI badges and clears as a unit. */
fun DashboardCard.isSample(): Boolean = id.startsWith(SampleData.PREFIX)
fun LiveActivitySession.isSample(): Boolean = externalActivityId.startsWith(SampleData.PREFIX)

/**
 * Kotlin port of ios/Sources/Shared/SampleDataFactory.swift's user-facing
 * deck: `makeCards()` (the "Generate sample widgets" set) plus the two
 * `LiveActivitySample` sessions. The home-energy set and timeline fixture
 * are deliberately excluded, matching iOS: they belong to other campaigns,
 * not the default deck.
 *
 * Same rules as iOS: ids live in the reserved `sample-` namespace so UI can
 * badge them and removal never mistakes a published card for a demo one;
 * samples never touch the server (generate/clear is local in SampleStore).
 * Values mirror the Swift source field-for-field; only dates are fresh
 * (`now`), since stale timestamps would render every sample stale.
 */
object SampleData {
    const val PREFIX = "sample-"

    fun sampleId(suffix: String): String = PREFIX + suffix

    private fun now(): String = Instant.now().toString()
    private fun plusMinutes(minutes: Long): String =
        Instant.now().plusSeconds(minutes * 60).toString()
    private fun minusMinutes(minutes: Long): String =
        Instant.now().minusSeconds(minutes * 60).toString()

    fun makeCards(): List<DashboardCard> = listOf(
        DashboardCard(
            id = sampleId("launch"),
            template = DashboardTemplate.BRIEFING,
            title = "Launch",
            subtitle = "Release Agent · final approval",
            value = "4/5",
            status = DashboardStatus.WARNING,
            icon = "shippingbox.fill",
            producer = CardProducer(label = "Release Agent", icon = "sparkles"),
            progress = 0.8,
            updatedAt = now(),
            briefing = DashboardBriefing(
                sections = listOf(
                    BriefingSection(id = "now", label = "Now", text = "Store uploaded; website live."),
                    BriefingSection(
                        id = "next",
                        label = "Next",
                        text = "Start the 10% rollout and publish the release notes after approval.",
                    ),
                    BriefingSection(
                        id = "needs-you",
                        label = "Needs you",
                        text = "Approve the customer announcement.",
                    ),
                ),
            ),
            // Consequential: routes through confirmation, never auto-runs.
            actions = listOf(
                ActionDefinition(id = "approve-launch", label = "Approve", confirm = true),
            ),
        ),
        DashboardCard(
            id = sampleId("production"),
            template = DashboardTemplate.LIST,
            title = "Production",
            subtitle = "Ops Agent · checked now",
            status = DashboardStatus.GOOD,
            icon = "server.rack",
            producer = CardProducer(label = "Ops Agent", icon = "gearshape.2"),
            updatedAt = now(),
            items = listOf(
                DashboardItem(id = "api", title = "API", value = "118", unit = "ms", status = DashboardStatus.GOOD, amount = 118.0),
                DashboardItem(id = "checkout", title = "Store", value = "99.99", unit = "%", status = DashboardStatus.GOOD, amount = 99.99),
                DashboardItem(id = "queue", title = "Queue", value = "0", unit = "waiting", status = DashboardStatus.GOOD, amount = 0.0),
            ),
        ),
        DashboardCard(
            id = sampleId("trials"),
            template = DashboardTemplate.CHART,
            title = "Trials",
            subtitle = "This week",
            value = "128",
            unit = "today",
            status = DashboardStatus.GOOD,
            icon = "chart.line.uptrend.xyaxis",
            producer = CardProducer(label = "Growth Agent", icon = "sparkles"),
            comparison = CardComparison(value = "+18", label = "vs Monday", signal = "favorable"),
            updatedAt = now(),
            chart = DashboardChart(
                points = listOf(110.0, 111.0, 114.0, 116.0, 119.0, 123.0, 128.0),
                min = 108.0,
                max = 130.0,
                reference = 110.0,
                referenceMetadata = ChartReferenceMetadata(
                    label = "Monday",
                    semantic = MetricSemantic(role = "baseline"),
                ),
                semantic = MetricSemantic(role = "actual", signal = "favorable"),
                style = "line",
                labels = listOf("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Today"),
            ),
        ),
        DashboardCard(
            id = sampleId("support"),
            template = DashboardTemplate.BREAKDOWN,
            title = "Support",
            subtitle = "1 waiting",
            value = "24",
            status = DashboardStatus.GOOD,
            icon = "person.2.wave.2",
            producer = CardProducer(label = "Support Agent", icon = "sparkles"),
            updatedAt = now(),
            items = listOf(
                DashboardItem(id = "waiting", title = "Waiting", value = "1", status = DashboardStatus.WARNING, amount = 1.0),
                DashboardItem(id = "resolved", title = "Resolved", value = "18", status = DashboardStatus.GOOD, amount = 18.0),
                DashboardItem(id = "draft-ready", title = "Draft ready", value = "5", status = DashboardStatus.RUNNING, amount = 5.0),
            ),
            actions = listOf(ActionDefinition(id = "open-support", label = "Review")),
        ),
        DashboardCard(
            id = sampleId("ai-spend"),
            template = DashboardTemplate.PROGRESS,
            title = "AI spend",
            subtitle = "of $30 · $11.60 left",
            value = "$18.40",
            status = DashboardStatus.GOOD,
            icon = "dollarsign.circle",
            producer = CardProducer(label = "Usage Agent", icon = "sparkles"),
            progress = 0.613,
            updatedAt = now(),
        ),
        DashboardCard(
            id = sampleId("agent-runs"),
            template = DashboardTemplate.HISTORY,
            title = "Agent runs",
            subtitle = "19 clean · 1 retried",
            value = "20/20",
            status = DashboardStatus.GOOD,
            icon = "checkmark.circle",
            producer = CardProducer(label = "Run Agent", icon = "sparkles"),
            updatedAt = now(),
            items = (1..20).map { n ->
                DashboardItem(
                    id = n.toString(),
                    title = "Run $n",
                    subtitle = if (n == 20) "Recovered after retry" else null,
                    value = "Passed",
                    status = DashboardStatus.GOOD,
                )
            },
        ),
        DashboardCard(
            id = sampleId("open-prs"),
            template = DashboardTemplate.SUMMARY,
            title = "Open PRs",
            subtitle = "All reviewed",
            value = "3",
            status = DashboardStatus.GOOD,
            icon = "arrow.triangle.branch",
            producer = CardProducer(label = "Code Agent", icon = "chevron.left.forwardslash.chevron.right"),
            updatedAt = now(),
        ),
    )

    enum class LiveActivitySample(val title: String) {
        APP_LAUNCH("App launch"),
        CAPTURE_WORKFLOW("Screenshot capture"),
    }

    fun makeLiveActivitySession(sample: LiveActivitySample): LiveActivitySession {
        return when (sample) {
            LiveActivitySample.APP_LAUNCH -> appLaunchSession()
            LiveActivitySample.CAPTURE_WORKFLOW -> captureWorkflowSession()
        }
    }

    private fun appLaunchSession(): LiveActivitySession {
        val now = now()
        return LiveActivitySession(
            externalActivityId = sampleId("app-launch"),
            kind = "job",
            title = "App launch",
            subtitle = "Version 2.4 · five steps",
            state = "Waiting for approval",
            signal = "caution",
            icon = "shippingbox.fill",
            statusIcon = "person.crop.circle.badge.exclamationmark",
            value = "4/5",
            progress = 0.8,
            items = listOf(
                LiveActivityItem(id = "announcement", title = "Announcement", value = "Needs approval", status = DashboardStatus.WARNING),
                LiveActivityItem(id = "store", title = "Store", value = "Uploaded", status = DashboardStatus.FINISHED),
                LiveActivityItem(id = "website", title = "Website", value = "Live", status = DashboardStatus.FINISHED),
                LiveActivityItem(id = "tests", title = "Tests", value = "412 passed", status = DashboardStatus.FINISHED),
                LiveActivityItem(id = "build", title = "Build", value = "Passed", status = DashboardStatus.FINISHED),
            ),
            // Deliberately no endsAt: blocked on a person, and an ETA beside
            // "Waiting for approval" pretends a clock can predict a decision.
            startedAt = minusMinutes(32),
            updatedAt = now,
            staleAt = plusMinutes(60),
        )
    }

    private fun captureWorkflowSession(): LiveActivitySession {
        val now = now()
        return LiveActivitySession(
            externalActivityId = sampleId("screenshot-capture"),
            kind = "job",
            title = "Screenshots",
            subtitle = "Four device sets",
            state = "running",
            signal = "neutral",
            icon = "camera",
            statusIcon = "play.fill",
            value = "1/4",
            progress = 0.25,
            items = listOf(
                LiveActivityItem(
                    id = "iphone-63",
                    title = "iPhone 6.3\"",
                    subtitle = "UI tests running",
                    icon = "iphone",
                    value = "6m 30s",
                    progress = 0.6,
                    status = DashboardStatus.RUNNING,
                ),
                // No status on the queued rows: a valueless row falls back
                // to its status label, and "Unknown" reads as a fault rather
                // than a turn that hasn't come yet.
                LiveActivityItem(id = "iphone-65", title = "iPhone 6.5\"", subtitle = "Queued", icon = "iphone"),
                LiveActivityItem(id = "ipad", title = "iPad", subtitle = "Queued", icon = "ipad"),
                LiveActivityItem(id = "apple-tv", title = "Apple TV", subtitle = "Queued", icon = "appletv"),
            ),
            endsAt = plusMinutes(37),
            startedAt = now,
            updatedAt = now,
            staleAt = plusMinutes(60),
        )
    }
}
