import Foundation
import Testing
@testable import ZeroZeroWidgetApp

@Suite("API client request encoding")
struct APIClientEncodingTests {
    @Test("Device approval uses the Worker's snake-case field")
    func deviceApprovalUsesSnakeCase() throws {
        let data = try CardCache.jsonEncoder().encode(
            DeviceAuthorizationApprovalBody(userCode: "ABCD-2345")
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: String]
        )
        #expect(object == ["user_code": "ABCD-2345"])
    }
}
