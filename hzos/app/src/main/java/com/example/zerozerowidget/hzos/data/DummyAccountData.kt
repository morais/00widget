package com.example.zerozerowidget.hzos.data

/**
 * Stand-in values for the account data the Settings screen puts on display:
 * the agent token.
 *
 * Ported field-for-field from iOS `DummyAccountData` — for a screenshot, a
 * demo, or a shared screen. The substitution is purely presentational:
 * nothing here is stored, sent, or written over the real credential, and
 * every request still goes out on the real token.
 */
object DummyAccountData {
    /**
     * Reserved by IANA for exactly this, so the address cannot belong to
     * anyone and cannot receive mail. Horizon has no signed-in email row to
     * swap, but the footer copy names it the same way iOS does.
     */
    const val EMAIL = "demo.agent@test.com"

    /**
     * Shaped like a real token — `zw_` plus URL-safe characters — so the row
     * wraps the way it will for the reader's own key, while reading as an
     * obvious placeholder to anyone who looks at it.
     */
    const val API_KEY = "zw_EXAMPLE_TOKEN_NOT_REAL_DO_NOT_USE0000000000"
}
