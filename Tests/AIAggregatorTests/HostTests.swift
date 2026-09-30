import Testing
import Foundation
import Network
import SQLite3
@testable import AIAggregator

@Suite("Hosts")
@MainActor
struct HostTests {
    private static func request(_ id: String, host: String?) -> RequestSpeed {
        var r = RequestSpeed(id: id, model: "gpt-6-luna", inputTokens: 10, outputTokens: 20,
                             durationMs: 1000, ttftMs: 100, date: Date())
        r.host = host
        return r
    }

    @Test func tailnetRange() {
        #expect(Tailnet.contains(IPv4Address("100.88.137.99")!))
        #expect(Tailnet.contains(IPv4Address("100.64.0.1")!))
        #expect(Tailnet.contains(IPv4Address("100.127.255.254")!))
        #expect(!Tailnet.contains(IPv4Address("100.128.0.1")!))
        #expect(!Tailnet.contains(IPv4Address("192.168.0.219")!))
        #expect(!Tailnet.contains(.loopback))
        #expect(Tailnet.shortName("mini4.tail2217fd.ts.net.") == "mini4")
        #expect(HostName.label(nil) == HostName.local)
        #expect(HostName.label("mini4") == "mini4")
    }

    @Test func hostRoundTripsAndGroupsStats() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = RequestLog(directory: dir, source: .codex)
        log.record([Self.request("a", host: "mini4"), Self.request("b", host: nil), Self.request("c", host: "mini4")], prompts: [])

        let reloaded = RequestLog(directory: dir, source: .codex)
        #expect(Dictionary(uniqueKeysWithValues: reloaded.requests.map { ($0.id, $0.host) }) == ["a": "mini4", "b": nil, "c": "mini4"])
        let byHost = reloaded.database.stats(from: nil, to: nil, by: .host)
        #expect(byHost.map(\.key) == ["mini4", ""])
        #expect(byHost.map(\.stats.requests) == [2, 1])
    }

    @Test func oldDatabaseGainsHostColumn() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The 1.7 schema, with one row in it.
        var db: OpaquePointer?
        sqlite3_open(dir.appendingPathComponent("claude-code.sqlite").path, &db)
        sqlite3_exec(db, """
            CREATE TABLE requests (id TEXT PRIMARY KEY, date REAL NOT NULL, model TEXT NOT NULL,
              success INTEGER NOT NULL, error TEXT, input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL,
              uncached_input_tokens INTEGER, cache_read_tokens INTEGER, cache_creation_tokens INTEGER,
              duration_ms REAL NOT NULL, ttft_ms REAL, cost_usd REAL, query_source TEXT, prompt_id TEXT,
              session_id TEXT, attempt INTEGER, attributes TEXT NOT NULL);
            INSERT INTO requests VALUES ('old', 1790000000, 'claude-fable-5-1', 1, NULL, 5, 50, 5, 0, 0,
              2000, 500, 0.01, NULL, NULL, NULL, NULL, '{}');
            """, nil, nil, nil)
        sqlite3_close(db)

        let log = RequestLog(directory: dir)
        #expect(log.requests.map(\.id) == ["old"])
        #expect(log.requests.first?.host == nil)
        log.record([Self.request("new", host: "mini4")], prompts: [])
        #expect(RequestLog(directory: dir).requests.first { $0.id == "new" }?.host == "mini4")
    }

    @Test func hostFilterHidesAMachine() {
        let defaults = UserDefaults(suiteName: "com.graywzc.AIAggregator.tests.\(UUID().uuidString)")!
        let filter = ModelFilter(defaults: defaults, source: .codex, field: .host)
        let requests = [Self.request("a", host: "mini4"), Self.request("b", host: nil)]
        #expect(ModelFilter.models(in: requests, field: .host).map(\.model) == ["", "mini4"])
        filter.set("mini4", shown: false)
        #expect(filter.apply(requests).map(\.id) == ["b"])
        #expect(defaults.stringArray(forKey: ModelFilter.key(for: .codex, field: .host)) == ["mini4"])
        #expect(ModelFilter(defaults: defaults, source: .codex).hidden.isEmpty)   // the model filter is separate
    }
}
