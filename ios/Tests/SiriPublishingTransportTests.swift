import Foundation
import Testing
@testable import ZeroZeroWidgetApp

private final class SiriPublishingURLProtocol: URLProtocol {
    static var responseBody = "{}"
    static var lastRequest: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.responseBody.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Siri publishing transport", .serialized)
struct SiriPublishingTransportTests {
    private func client() -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SiriPublishingURLProtocol.self]
        return APIClient(config: APIClientConfig(baseURL: URL(string: "https://unit-test.invalid")!, apiKey: "test-publisher"), session: URLSession(configuration: configuration))
    }

    @Test("All publications use the existing authenticated API routes")
    func publicationRoutes() async throws {
        let api = client()
        for operation in [APIClient.PublishingOperation.card, .startActivity, .updateActivity, .endActivity] {
            SiriPublishingURLProtocol.responseBody = operation == .card ? #"{"card":{"id":"new"}}"# : #"{"ok":true}"#
            _ = try await api.publish(PublishingDocument(json: #"{"progress":0.25,"endsAt":null}"#), operation: operation)
            let request = try #require(SiriPublishingURLProtocol.lastRequest)
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == operation.rawValue)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-publisher")
        }
    }

    @Test("Activity management refuses an older server that ignores ownership filtering")
    func ownershipFilterFailsClosed() async throws {
        SiriPublishingURLProtocol.responseBody = #"{"activities":[]}"#
        await #expect(throws: APIClientError.self) { try await client().fetchLiveActivities(ownedOnly: true) }
        #expect(SiriPublishingURLProtocol.lastRequest?.url?.query == "ownedOnly=true")
        SiriPublishingURLProtocol.responseBody = #"{"activities":[],"ownedOnly":true}"#
        #expect(try await client().fetchLiveActivities(ownedOnly: true).isEmpty)
        // Ordinary app refreshes remain compatible with older servers.
        SiriPublishingURLProtocol.responseBody = #"{"activities":[]}"#
        #expect(try await client().fetchLiveActivities().isEmpty)
    }
}
