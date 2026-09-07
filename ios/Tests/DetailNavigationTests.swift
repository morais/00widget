import Testing
@testable import ZeroZeroWidgetApp

@Suite("Detail navigation availability")
struct DetailNavigationTests {
    @Test("An available destination remains selected")
    func availableDestinationRemainsSelected() {
        #expect(
            DetailNavigation.missingDestination(
                in: ["solar"],
                availableDestinations: ["solar", "washer"]
            ) == nil
        )
    }

    @Test("A removed destination is identified")
    func removedDestinationIsIdentified() {
        #expect(
            DetailNavigation.missingDestination(
                in: ["activity-1"],
                availableDestinations: ["activity-2"]
            ) == "activity-1"
        )
    }

    @Test("An empty navigation stack has nothing to invalidate")
    func emptyPathRemainsEmpty() {
        #expect(
            DetailNavigation.missingDestination(
                in: [],
                availableDestinations: []
            ) == nil
        )
    }

    @Test("Namespaced shared widget destinations are compared exactly")
    func namespacedDestinationsRemainDistinct() {
        #expect(
            DetailNavigation.missingDestination(
                in: ["shared:solar"],
                availableDestinations: ["solar", "guest:solar"]
            ) == "shared:solar"
        )
    }
}
