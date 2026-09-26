import Testing
import Foundation
@testable import AIAggregator

@Suite("ModelFilter")
struct ModelFilterTests {
    private static func request(_ id: String, model: String) -> RequestSpeed {
        RequestSpeed(id: id, model: model, inputTokens: 10, outputTokens: 20, durationMs: 1000, ttftMs: 100, date: Date())
    }

    private let requests = [
        ("a", "claude-fable-5-1"), ("b", "claude-haiku-4-5-20251001"), ("c", "claude-fable-5-1"), ("d", ""),
    ].map { request($0.0, model: $0.1) }

    private func makeFilter() -> (ModelFilter, UserDefaults) {
        let name = "com.graywzc.AIAggregator.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (ModelFilter(defaults: defaults), defaults)
    }

    @Test func nothingHiddenKeepsEveryRequest() {
        let (filter, _) = makeFilter()
        #expect(!filter.isActive)
        #expect(filter.apply(requests).map(\.id) == ["a", "b", "c", "d"])
    }

    @Test func hiddenModelsAreDropped() {
        let (filter, _) = makeFilter()
        filter.set("claude-fable-5-1", shown: false)
        filter.set("", shown: false)
        #expect(filter.isActive)
        #expect(filter.apply(requests).map(\.id) == ["b"])
        filter.set("claude-fable-5-1", shown: true)
        #expect(filter.apply(requests).map(\.id) == ["a", "b", "c"])
    }

    @Test func hiddenSetPersistsAndOldPickerKeyIsCleared() {
        let (filter, defaults) = makeFilter()
        defaults.set("claude-opus-5-5", forKey: "ClaudeCodeRequestsModel")
        filter.hidden = ["claude-opus-5-5", "claude-fable-5-1"]
        #expect(defaults.stringArray(forKey: ModelFilter.key) == ["claude-fable-5-1", "claude-opus-5-5"])
        let reloaded = ModelFilter(defaults: defaults)
        #expect(reloaded.hidden == ["claude-opus-5-5", "claude-fable-5-1"])
        #expect(defaults.object(forKey: "ClaudeCodeRequestsModel") == nil)
    }

    @Test func modelsAreSortedWithCounts() {
        let models = ModelFilter.models(in: requests)
        #expect(models.map(\.model) == ["", "claude-fable-5-1", "claude-haiku-4-5-20251001"])
        #expect(models.map(\.count) == [1, 2, 1])
        #expect(ModelFilter.label("") == "(unknown)")
        #expect(ModelFilter.label("claude-fable-5-1") == "fable-5-1")
    }
}
