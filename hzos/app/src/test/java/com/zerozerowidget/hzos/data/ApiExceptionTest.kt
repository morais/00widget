package com.zerozerowidget.hzos.data

import org.junit.Assert.assertEquals
import org.junit.Test

/** What a failed Worker call puts on screen: the server's words or the status, never the body. */
class ApiExceptionTest {
    @Test
    fun usesTheServersErrorField() {
        val e = ZeroWidgetApi.ApiException(429, """{"error":"rate limit exceeded","retryAfter":30}""")
        assertEquals("rate limit exceeded", e.message)
    }

    @Test
    fun neverShowsARawBody() {
        assertEquals("HTTP 502", ZeroWidgetApi.ApiException(502, "<html><body>Bad gateway</body></html>").message)
        assertEquals("HTTP 500", ZeroWidgetApi.ApiException(500, "").message)
        assertEquals("HTTP 400", ZeroWidgetApi.ApiException(400, """{"error":""}""").message)
    }
}
