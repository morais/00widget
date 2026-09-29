package com.zerozerowidget.hzos.ui

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The text floor set in Theme.kt: anything a user must read is body or
 * larger. A source scan, since the styles are plain property reads that no
 * lint rule can tell apart: bodySmall nowhere, caption only in chart code.
 */
class TextFloorTest {
    private val sources = File("src/main/java").walkTopDown().filter { it.extension == "kt" }.toList()

    private fun uses(style: String) = sources.flatMap { file ->
        file.readLines().mapIndexedNotNull { index, line ->
            "${file.name}:${index + 1}".takeIf { "LocalTypography.current.$style" in line }
        }
    }

    @Test
    fun theSourcesAreWhereTheTestLooks() {
        assertTrue("no sources found from ${File(".").absolutePath}", sources.isNotEmpty())
    }

    @Test
    fun nothingReadsAtBodySmall() {
        assertEquals(emptyList<String>(), uses("bodySmall"))
    }

    @Test
    fun captionIsForChartAnnotationsOnly() {
        val chartFiles = setOf("Plots.kt", "CardViews.kt")
        assertEquals(emptyList<String>(), uses("caption").filter { it.substringBefore(':') !in chartFiles })
    }
}
