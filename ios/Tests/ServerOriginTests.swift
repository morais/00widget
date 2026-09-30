import Testing
@testable import ZeroZeroWidgetApp

@Suite("Server credential origin")
struct ServerOriginTests {
    @Test func pathsAndDefaultPortKeepCredentials() {
        #expect(APIClientConfig.hasSameOrigin("https://API.example.com/v1", "https://api.example.com:443/new"))
    }

    @Test func hostSchemeAndPortChangesClearCredentials() {
        #expect(!APIClientConfig.hasSameOrigin("https://api.example.com", "https://other.example.com"))
        #expect(!APIClientConfig.hasSameOrigin("https://api.example.com", "https://api.example.com:8443"))
        #expect(!APIClientConfig.hasSameOrigin("http://localhost:8787", "https://localhost:8787"))
        #expect(!APIClientConfig.hasSameOrigin("https://api.example.com", "invalid"))
    }
}
