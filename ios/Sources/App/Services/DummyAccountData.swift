import Foundation

/// Stand-in values for the two pieces of account data the Settings screen puts
/// on display: the signed-in address and the agent token.
///
/// For a screenshot, a demo, or a shared screen. The substitution is purely
/// presentational — nothing here is stored, sent, or written over the real
/// credential, and every request still goes out on the real token.
enum DummyAccountData {
    /// `test.com` is reserved by IANA for exactly this, so the address cannot
    /// belong to anyone and cannot receive mail.
    static let email = "demo.agent@test.com"

    /// Shaped like a real token — `zw_` plus 43 URL-safe characters — so the
    /// row wraps and truncates the way it will for the reader's own key, while
    /// reading as an obvious placeholder to anyone who looks at it.
    static let apiKey = "zw_EXAMPLE_TOKEN_NOT_REAL_DO_NOT_USE0000000000"
}
