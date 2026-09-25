import Testing
import Foundation
@testable import AIAggregator

@Suite("SpeedStats")
@MainActor
struct SpeedStatsTests {

    // Envelope and value encoding copied from a real Claude Code 2.1.217 export.
    private func spanPayload(success: Bool, extra: String = "") -> Data {
        Data("""
        {"resourceSpans":[{"scopeSpans":[{"spans":[
          {"traceId":"06f9","spanId":"14b2","name":"claude_code.interaction","attributes":[]},
          {"traceId":"06f9","spanId":"99aa","name":"claude_code.llm_request",
           "startTimeUnixNano":"1790017061589000000","endTimeUnixNano":"1790017071589000000",
           "attributes":[
             {"key":"model","value":{"stringValue":"claude-fable-5-1"}},
             {"key":"duration_ms","value":{"intValue":10000}},
             {"key":"success","value":{"boolValue":\(success)}},
             {"key":"client_request_id","value":{"stringValue":"req-1"}}\(extra)
           ]}
        ]}]}]}
        """.utf8)
    }

    private let tokenAttributes = """
        ,{"key":"input_tokens","value":{"intValue":100}}
        ,{"key":"cache_read_tokens","value":{"intValue":"3800"}}
        ,{"key":"cache_creation_tokens","value":{"intValue":100}}
        ,{"key":"output_tokens","value":{"intValue":400}}
        ,{"key":"ttft_ms","value":{"intValue":2000}}
        """

    @Test func parsesSuccessfulRequestSpan() throws {
        let parsed = OTLPParser.parse(spanPayload(success: true, extra: tokenAttributes))
        let r = try #require(parsed.first)
        #expect(parsed.count == 1)
        #expect(r.id == "req-1")
        #expect(r.model == "claude-fable-5-1")
        #expect(r.inputTokens == 4000)      // string-encoded intValue included
        #expect(r.outputTokens == 400)
        #expect(r.ttftMs == 2000)
        #expect(r.date == Date(timeIntervalSince1970: 1790017071.589))
        #expect(r.genTokensPerSec == 50)       // 400 tokens over the 8s after first token
    }

    @Test func skipsFailedRequestSpan() {
        #expect(OTLPParser.parse(spanPayload(success: false, extra: tokenAttributes)).isEmpty)
    }

    @Test func skipsSpanWithoutTokenCounts() {
        #expect(OTLPParser.parse(spanPayload(success: true)).isEmpty)
    }

    @Test func parsesApiRequestLogEvent() throws {
        let payload = Data("""
        {"resourceLogs":[{"scopeLogs":[{"logRecords":[
          {"timeUnixNano":"1790017061598000000","body":{"stringValue":"claude_code.user_prompt"},
           "attributes":[{"key":"event.name","value":{"stringValue":"user_prompt"}}]},
          {"timeUnixNano":"1790017061598000000","body":{"stringValue":"claude_code.api_request"},
           "attributes":[
             {"key":"event.name","value":{"stringValue":"api_request"}},
             {"key":"model","value":{"stringValue":"claude-haiku-4-5-20251001"}},
             {"key":"duration_ms","value":{"intValue":4000}},
             {"key":"input_tokens","value":{"intValue":10}},
             {"key":"output_tokens","value":{"intValue":200}}
           ]}
        ]}]}]}
        """.utf8)
        let r = try #require(OTLPParser.parse(payload).first)
        #expect(r.ttftMs == nil)
        #expect(r.genTokensPerSec == 50)       // falls back to whole-request duration
    }

    @Test func ignoresGarbage() {
        #expect(OTLPParser.parse(Data("not json".utf8)).isEmpty)
        #expect(OTLPParser.parse(Data("{}".utf8)).isEmpty)
    }

    @Test func shortRequestsHaveNoGenerationRate() {
        let r = RequestSpeed(id: "a", model: "m", inputTokens: 10, outputTokens: 5,
                             durationMs: 500, ttftMs: 400, date: Date())
        #expect(r.genTokensPerSec == nil)
    }

    @Test func recordDedupesPreferringTtft() {
        let svc = SpeedStatsService()
        let t = Date(timeIntervalSince1970: 1_000)
        let fromLog  = RequestSpeed(id: "req-1", model: "m", inputTokens: 10, outputTokens: 100,
                                    durationMs: 2000, ttftMs: nil, date: t)
        let fromSpan = RequestSpeed(id: "req-1", model: "m", inputTokens: 10, outputTokens: 100,
                                    durationMs: 2000, ttftMs: 1000, date: t)
        svc.record([fromLog])
        svc.record([fromSpan])
        svc.record([fromLog])
        #expect(svc.recent == [fromSpan])
        #expect(svc.compact == "100t/s")
    }

    @Test func latestSkipsShortRequestsAndCapsHistory() {
        let svc = SpeedStatsService()
        let many = (0..<(SpeedStatsService.maxRecent + 10)).map { i in
            RequestSpeed(id: "r\(i)", model: "m", inputTokens: 10, outputTokens: 100,
                         durationMs: 1000, ttftMs: nil, date: Date(timeIntervalSince1970: Double(i)))
        }
        let short = RequestSpeed(id: "short", model: "m", inputTokens: 10, outputTokens: 3,
                                 durationMs: 100, ttftMs: nil, date: Date(timeIntervalSince1970: 9_999))
        svc.record(many + [short])
        #expect(svc.recent.count == SpeedStatsService.maxRecent)
        #expect(svc.recent.last?.id == "short")
        #expect(svc.latest?.id == "r\(SpeedStatsService.maxRecent + 9)")
    }

    @Test func latestPrefersRequestWithTtft() {
        let svc = SpeedStatsService()
        let withTtft = RequestSpeed(id: "a", model: "m", inputTokens: 4000, outputTokens: 100,
                                    durationMs: 2000, ttftMs: 1000, date: Date(timeIntervalSince1970: 1))
        let logOnly  = RequestSpeed(id: "b", model: "m", inputTokens: 5000, outputTokens: 100,
                                    durationMs: 2000, ttftMs: nil, date: Date(timeIntervalSince1970: 2))
        svc.record([withTtft, logOnly])
        #expect(svc.latest?.id == "a")
        #expect(svc.compact == "100t/s") // logOnly counts the wait, so it is left out
    }

    @Test func averageWeightsByTokens() {
        let svc = SpeedStatsService()
        let normal = RequestSpeed(id: "a", model: "m", inputTokens: 10, outputTokens: 1000,
                                  durationMs: 11_000, ttftMs: 1000, date: Date(timeIntervalSince1970: 1))
        let burst  = RequestSpeed(id: "b", model: "m", inputTokens: 10, outputTokens: 100,
                                  durationMs: 1010, ttftMs: 1000, date: Date(timeIntervalSince1970: 2))
        svc.record([normal, burst])
        // Per-request rates are 100 and 10,000; the mean would be 5,050.
        #expect(svc.compact == "110t/s") // 1,100 tokens in 10.01s
    }

    // MARK: - Per-request log

    private let detailedLogs = Data("""
        {"resourceLogs":[{"scopeLogs":[{"logRecords":[
          {"timeUnixNano":"1790017061000000000","attributes":[
             {"key":"event.name","value":{"stringValue":"user_prompt"}},
             {"key":"prompt.id","value":{"stringValue":"p-1"}},
             {"key":"prompt","value":{"stringValue":"fix the bug"}}]},
          {"timeUnixNano":"1790017061500000000","attributes":[
             {"key":"event.name","value":{"stringValue":"user_prompt"}},
             {"key":"prompt.id","value":{"stringValue":"p-2"}},
             {"key":"prompt","value":{"stringValue":"<REDACTED>"}}]},
          {"timeUnixNano":"1790017062000000000","attributes":[
             {"key":"event.name","value":{"stringValue":"api_error"}},
             {"key":"prompt.id","value":{"stringValue":"p-1"}},
             {"key":"client_request_id","value":{"stringValue":"req-1"}},
             {"key":"attempt","value":{"intValue":1}},
             {"key":"error","value":{"stringValue":"overloaded"}},
             {"key":"duration_ms","value":{"intValue":300}}]},
          {"timeUnixNano":"1790017070000000000","attributes":[
             {"key":"event.name","value":{"stringValue":"api_request"}},
             {"key":"prompt.id","value":{"stringValue":"p-1"}},
             {"key":"client_request_id","value":{"stringValue":"req-1"}},
             {"key":"session.id","value":{"stringValue":"s-1"}},
             {"key":"user.email","value":{"stringValue":"someone@example.com"}},
             {"key":"query_source","value":{"stringValue":"repl_main_thread"}},
             {"key":"cost_usd","value":{"doubleValue":0.0123}},
             {"key":"model","value":{"stringValue":"claude-opus-5-5"}},
             {"key":"duration_ms","value":{"intValue":5000}},
             {"key":"input_tokens","value":{"intValue":7}},
             {"key":"cache_read_tokens","value":{"intValue":900}},
             {"key":"cache_creation_tokens","value":{"intValue":93}},
             {"key":"output_tokens","value":{"intValue":250}}]}
        ]}]}]}
        """.utf8)

    @Test func parsesDetailsErrorsAndPrompts() throws {
        let batch = OTLPParser.parseBatch(detailedLogs)
        #expect(batch.prompts == [PromptRecord(id: "p-1", text: "fix the bug",
                                               date: Date(timeIntervalSince1970: 1790017061))])
        #expect(batch.requests.count == 2)

        let failure = batch.requests[0]
        #expect(!failure.success)
        #expect(failure.error == "overloaded")
        #expect(failure.id == "req-1#error1")    // doesn't collide with the retry that succeeded
        #expect(failure.genTokensPerSec == nil)

        let ok = batch.requests[1]
        #expect(ok.id == "req-1")
        #expect(ok.inputTokens == 1000)
        #expect(ok.uncachedInputTokens == 7)
        #expect(ok.cacheReadTokens == 900)
        #expect(ok.cacheCreationTokens == 93)
        #expect(ok.costUsd == 0.0123)
        #expect(ok.querySource == "repl_main_thread")
        #expect(ok.sessionId == "s-1")
        #expect(ok.attributes["cost_usd"] == "0.0123")
        #expect(ok.attributes["user.email"] == nil)   // account identifiers aren't stored
    }

    @Test func failuresStayOutOfSpeedStats() {
        let svc = SpeedStatsService()
        svc.record(OTLPParser.parse(detailedLogs))
        #expect(svc.recent.map(\.id) == ["req-1"])
    }

    @Test func logMergesSpanAndEventAndPersists() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = RequestLog(directory: dir)
        let batch = OTLPParser.parseBatch(detailedLogs)
        log.record(batch.requests, prompts: batch.prompts)
        log.record(OTLPParser.parse(spanPayload(success: true, extra: tokenAttributes)), prompts: [])

        let merged = try #require(log.requests.first { $0.id == "req-1" })
        #expect(log.requests.count == 2)
        #expect(log.totalCount == 2)
        #expect(merged.ttftMs == 2000)          // from the span
        #expect(merged.costUsd == 0.0123)       // from the log event
        #expect(merged.attributes["stop_reason"] == nil)
        #expect(log.promptText(for: merged) == "fix the bug")

        let reloaded = RequestLog(directory: dir)
        #expect(reloaded.requests == log.requests)
        #expect(reloaded.totalCount == 2)
        #expect(reloaded.promptText(for: merged) == "fix the bug")
        #expect(reloaded.database.openError == nil)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("claude-code.sqlite").path))
    }

    @Test func logImportsLegacyJSONLOnce() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // What 1.5.0 wrote: one JSON object per line, a request possibly twice (event, then span).
        let batch = OTLPParser.parseBatch(detailedLogs)
        let span = try #require(OTLPParser.parse(spanPayload(success: true, extra: tokenAttributes)).first)
        let encoder = JSONEncoder()
        var lines = Data()
        for r in batch.requests + [span] { lines.append(try encoder.encode(r)); lines.append(UInt8(ascii: "\n")) }
        try lines.write(to: dir.appendingPathComponent(RequestLog.legacyRequestsFile))
        var promptLines = Data()
        for p in batch.prompts { promptLines.append(try encoder.encode(p)); promptLines.append(UInt8(ascii: "\n")) }
        try promptLines.write(to: dir.appendingPathComponent(RequestLog.legacyPromptsFile))

        let log = RequestLog(directory: dir)
        #expect(log.requests.count == 2)
        let merged = try #require(log.requests.first { $0.id == "req-1" })
        #expect(merged.ttftMs == 2000)
        #expect(merged.costUsd == 0.0123)
        #expect(log.promptText(for: merged) == "fix the bug")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(RequestLog.legacyRequestsFile).path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(RequestLog.legacyRequestsFile + ".imported").path))

        // A second launch doesn't find the files again and keeps the rows.
        #expect(RequestLog(directory: dir).totalCount == 2)
    }

    @Test func logKeepsOnlyRecentRowsInMemory() {
        let log = RequestLog(directory: nil)
        let many = (0..<(RequestLog.maxEntries + 5)).map { i in
            RequestSpeed(id: "r\(i)", model: "m", inputTokens: 1, outputTokens: 1,
                         durationMs: 1, ttftMs: nil, date: Date(timeIntervalSince1970: Double(i)))
        }
        log.record(many, prompts: [])
        #expect(log.requests.count == RequestLog.maxEntries)
        #expect(log.requests.first?.id == "r5")
        #expect(log.totalCount == RequestLog.maxEntries + 5)

        log.clear()
        #expect(log.requests.isEmpty)
        #expect(log.totalCount == 0)
        #expect(log.database.stats(from: nil, to: nil, by: .total).isEmpty)
    }

    // MARK: - Stats

    private func sample(_ id: String, model: String, day: Int, out: Int, ms: Double, ttft: Double?,
                        cost: Double?, success: Bool = true) -> RequestSpeed {
        var r = RequestSpeed(id: id, model: model, inputTokens: 1000, outputTokens: out,
                             durationMs: ms, ttftMs: ttft,
                             date: Calendar.current.date(byAdding: .day, value: -day, to: noon)!)
        r.costUsd = cost
        r.success = success
        return r
    }

    private var noon: Date {
        Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
    }

    @Test func statsAggregatePerModelAndPeriod() throws {
        let log = RequestLog(directory: nil)
        log.record([
            sample("a", model: "claude-opus-5-5", day: 0, out: 1000, ms: 11_000, ttft: 1000, cost: 0.50),
            sample("b", model: "claude-opus-5-5", day: 0, out: 100, ms: 1_010, ttft: 1000, cost: 0.05),
            sample("c", model: "claude-haiku-4-5", day: 0, out: 200, ms: 3_000, ttft: 1000, cost: 0.01),
            sample("d", model: "claude-haiku-4-5", day: 0, out: 5, ms: 500, ttft: 100, cost: 0.001),  // too short to rate
            sample("e", model: "claude-opus-5-5", day: 0, out: 0, ms: 300, ttft: nil, cost: nil, success: false),
            sample("g", model: "claude-sonnet-5", day: 0, out: 9, ms: 1_000, ttft: nil, cost: nil),  // side call, no cost
            sample("f", model: "claude-opus-5-5", day: 3, out: 500, ms: 6_000, ttft: 1000, cost: 2.00),
        ], prompts: [])
        let db = log.database

        let today = StatsPeriod.today.range()
        let byModel = db.stats(from: today.from, to: today.to, by: .model)
        #expect(byModel.map(\.key) == ["claude-opus-5-5", "claude-haiku-4-5", "claude-sonnet-5"])   // biggest spender first
        #expect(byModel.last?.stats.reportedCostUsd == nil)

        let opus = try #require(byModel.first?.stats)
        #expect(opus.requests == 2)
        #expect(opus.failures == 1)
        #expect(opus.outputTokens == 1100)
        #expect(opus.inputTokens == 2000)
        #expect(abs(opus.costUsd - 0.55) < 1e-9)
        #expect(opus.genTokensPerSec.map { Int($0.rounded()) } == 110)   // 1,100 tokens in 10.01s, not the mean of rates
        #expect(opus.averageTtftMs == 1000)

        let haiku = try #require(byModel[1].stats)
        #expect(haiku.requests == 2)
        #expect(haiku.genTokens == 200)                    // the 5-token request is left out of the rate
        #expect(haiku.genTokensPerSec == 100)
        #expect(abs(haiku.costUsd - 0.011) < 1e-9)
        #expect(haiku.costCount == 2)

        let all = try #require(db.stats(from: nil, to: nil, by: .total).first?.stats)
        #expect(all.requests == 6)
        #expect(abs(all.costUsd - 2.561) < 1e-9)

        let week = StatsPeriod.last7Days.range()
        let byDay = db.stats(from: week.from, to: week.to, by: .day)
        #expect(byDay.count == 2)
        #expect(byDay.first!.key > byDay.last!.key)         // newest day first
        #expect(byDay.last?.stats.costUsd == 2.00)

        let yesterday = StatsPeriod.yesterday.range()
        #expect(db.stats(from: yesterday.from, to: yesterday.to, by: .total).isEmpty)
    }

    @Test func periodRangesFollowTheLocalCalendar() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = try #require(cal.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 15)))
        func day(_ d: Int, _ m: Int = 9) -> Date { cal.date(from: DateComponents(year: 2026, month: m, day: d))! }

        #expect(StatsPeriod.today.range(now: now, calendar: cal) == (day(25), nil))
        #expect(StatsPeriod.yesterday.range(now: now, calendar: cal) == (day(24), day(25)))
        #expect(StatsPeriod.last7Days.range(now: now, calendar: cal) == (day(19), nil))
        #expect(StatsPeriod.last30Days.range(now: now, calendar: cal) == (day(27, 8), nil))
        #expect(StatsPeriod.thisMonth.range(now: now, calendar: cal) == (day(1), nil))
        #expect(StatsPeriod.all.range(now: now, calendar: cal) == (nil, nil))
    }

    // MARK: - HTTP framing

    private func request(_ body: String) -> Data {
        Data("POST /v1/traces HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\ncontent-length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
    }

    @Test func bufferReassemblesSplitRequest() {
        var buffer = HTTPRequestBuffer()
        let bytes = request("{\"a\":1}")
        buffer.append(bytes.prefix(30))
        #expect(buffer.nextBody() == nil)
        buffer.append(bytes.dropFirst(30))
        #expect(buffer.nextBody() == Data("{\"a\":1}".utf8))
        #expect(buffer.nextBody() == nil)
    }

    @Test func bufferHandlesKeepAlive() {
        var buffer = HTTPRequestBuffer()
        buffer.append(request("first") + request("second"))
        #expect(buffer.nextBody() == Data("first".utf8))
        #expect(buffer.nextBody() == Data("second".utf8))
        #expect(buffer.nextBody() == nil)
    }

    @Test func bufferRejectsOversizedBody() {
        var buffer = HTTPRequestBuffer()
        buffer.append(Data("POST / HTTP/1.1\r\nContent-Length: 99999999999\r\n\r\n".utf8))
        #expect(buffer.nextBody() == nil)
        #expect(buffer.isMalformed)
    }
}
