package com.zerozerowidget.hzos.data

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The hzos wire model against what producers really send: every card the
 * repository's examples/ scripts publish (all nine templates), plus the
 * fallbacks for values this build does not know. Models.kt is the third
 * hand copy of the model (after types.ts and Swift), and before this
 * nothing checked it against a real payload.
 *
 * These are producer inputs, which the Worker enriches on the way out
 * (legacy chart points, for one), so decoding them is a slightly stricter
 * test than decoding a /v1/dashboard response: a field the Worker derives
 * must still be optional here.
 */
class WireDecodingTest {
    private val examples = File("../../examples")

    /** The JSON body of each upsert script, `--data '…'` or a heredoc. */
    private fun examplePayloads(): Map<String, String> = examples.listFiles { f -> f.name.startsWith("upsert-") && f.name.endsWith(".sh") }!!
        .sortedBy { it.name }
        .associate { file ->
            val script = file.readText()
            val body = Regex("--data '(.*?)'", RegexOption.DOT_MATCHES_ALL).find(script)?.groupValues?.get(1)
                ?: Regex("<<JSON\\n(.*?)\\nJSON", RegexOption.DOT_MATCHES_ALL).find(script)?.groupValues?.get(1)
                ?: error("no JSON body in ${file.name}")
            // A heredoc may compute a date with $(date …); any date will do.
            file.name to body.replace(Regex("\\$\\([^\"]*\\)"), "2026-01-01T00:00:00Z")
        }

    @Test
    fun everyExampleCardDecodes() {
        val payloads = examplePayloads()
        assertTrue("found no example scripts under ${examples.absolutePath}", payloads.size >= 10)
        val templates = mutableSetOf<DashboardTemplate>()
        payloads.forEach { (name, json) ->
            val cards = if (json.contains("\"cards\"")) {
                WireJson.decodeFromString(DashboardResponse.serializer(), json).cards
            } else {
                listOf(WireJson.decodeFromString(DashboardCard.serializer(), json))
            }
            assertTrue("$name decoded no cards", cards.isNotEmpty())
            templates += cards.map { it.template }
        }
        assertEquals(
            "examples no longer cover every template",
            DashboardTemplate.entries.toSet(),
            templates
        )
    }

    @Test
    fun unknownTemplateAndStatusFallBackWithoutFailingTheDashboard() {
        val json = """
            {"cards": [
              {"id": "a", "template": "hologram", "title": "From a newer server", "status": "exploding"},
              {"id": "b", "template": "summary", "title": "Ordinary"}
            ]}
        """.trimIndent()
        val cards = WireJson.decodeFromString(DashboardResponse.serializer(), json).cards
        assertEquals(listOf("a", "b"), cards.map { it.id })
        assertEquals(DashboardTemplate.SUMMARY, cards[0].template)
        assertEquals(DashboardStatus.UNKNOWN, cards[0].status)
    }
}
