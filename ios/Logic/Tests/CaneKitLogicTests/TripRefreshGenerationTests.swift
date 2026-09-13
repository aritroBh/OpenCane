import Testing
@testable import CaneKitLogic

struct TripRefreshGenerationTests {
    @Test func aNewTripRejectsAnOlderHealthKitResult() {
        var fence = TripRefreshGeneration()
        let first = fence.begin()
        let second = fence.begin()

        #expect(first != second)
        #expect(!fence.accepts(first))
        #expect(fence.accepts(second))
    }

    @Test func cancelInvalidatesAnInFlightResult() {
        var fence = TripRefreshGeneration()
        let token = fence.begin()
        fence.invalidate()

        #expect(!fence.accepts(token))
    }
}
