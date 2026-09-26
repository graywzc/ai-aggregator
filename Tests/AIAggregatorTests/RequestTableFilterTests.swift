import Testing
import Foundation
@testable import AIAggregator

@Suite("RequestTableView model filter")
struct RequestTableFilterTests {
    private static func request(_ id: String, model: String) -> RequestSpeed {
        RequestSpeed(id: id, model: model, inputTokens: 10, outputTokens: 20, durationMs: 1000, ttftMs: 100, date: Date())
    }

    private let requests = [
        ("a", "claude-fable-5-1"), ("b", "claude-haiku-4-5-20251001"), ("c", "claude-fable-5-1"), ("d", ""),
    ].map { request($0.0, model: $0.1) }

    @Test func allModelsKeepsEveryRequest() {
        #expect(RequestTableView.filter(requests, model: RequestTableView.allModels).map(\.id) == ["a", "b", "c", "d"])
    }

    @Test func oneModelKeepsOnlyItsRequests() {
        #expect(RequestTableView.filter(requests, model: "claude-fable-5-1").map(\.id) == ["a", "c"])
        #expect(RequestTableView.filter(requests, model: "claude-opus-5-5").isEmpty)
    }

    @Test func optionsAreDistinctSortedModelsWithoutUnknown() {
        #expect(RequestTableView.modelOptions(requests, selected: RequestTableView.allModels)
                == ["claude-fable-5-1", "claude-haiku-4-5-20251001"])
    }

    @Test func optionsKeepAStoredModelNoLongerInTheRows() {
        #expect(RequestTableView.modelOptions(requests, selected: "claude-opus-5-5")
                == ["claude-fable-5-1", "claude-haiku-4-5-20251001", "claude-opus-5-5"])
    }
}
