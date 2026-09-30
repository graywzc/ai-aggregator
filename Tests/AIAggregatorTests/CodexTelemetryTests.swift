import Testing
import Foundation
@testable import AIAggregator

@Suite("CodexTelemetry")
@MainActor
struct CodexTelemetryTests {

    // Shaped like a real Codex 0.158 export: timeUnixNano left at 0, the time in event.timestamp.
    private func logs(_ events: [(name: String, time: String, attrs: String)]) -> Data {
        let records = events.map { e in
            """
            {"timeUnixNano":"0","observedTimeUnixNano":"1790734960000000000","attributes":[
              {"key":"event.name","value":{"stringValue":"\(e.name)"}},
              {"key":"event.timestamp","value":{"stringValue":"\(e.time)"}},
              {"key":"conversation.id","value":{"stringValue":"conv-1"}},
              {"key":"model","value":{"stringValue":"gpt-6-astra"}},
              {"key":"originator","value":{"stringValue":"codex_exec"}},
              {"key":"user.email","value":{"stringValue":"someone@example.com"}},
              {"key":"user.account_id","value":{"stringValue":"acct"}}\(e.attrs)
            ]}
            """
        }
        return Data("""
            {"resourceLogs":[{"scopeLogs":[{"scope":{"name":"codex_otel.log_only"},"logRecords":[\(records.joined(separator: ","))]}]}]}
            """.utf8)
    }

    private let prompt = (name: "codex.user_prompt", time: "2026-09-30T02:22:40.028Z",
                          attrs: #",{"key":"prompt","value":{"stringValue":"write about tides"}}"#)
    private let request = (name: "codex.websocket_request", time: "2026-09-30T02:22:46.292Z",
                           attrs: #",{"key":"duration_ms","value":{"stringValue":"2"}},{"key":"success","value":{"stringValue":"true"}}"#)
    private let completed = (name: "codex.sse_event", time: "2026-09-30T02:22:55.648Z", attrs: """
        ,{"key":"event.kind","value":{"stringValue":"response.completed"}}
        ,{"key":"input_token_count","value":{"stringValue":"17957"}}
        ,{"key":"output_token_count","value":{"stringValue":"220"}}
        ,{"key":"cached_token_count","value":{"stringValue":"17664"}}
        ,{"key":"cache_write_token_count","value":{"stringValue":"0"}}
        ,{"key":"reasoning_token_count","value":{"stringValue":"26"}}
        ,{"key":"ttft_ms","value":{"stringValue":"2737"}}
        ,{"key":"model_reasoning_effort","value":{"stringValue":"low"}}
        """)

    @Test func pairsRequestWithCompletedResponse() throws {
        let parser = CodexOTLPParser()
        let batch = parser.parseBatch(logs([prompt, request, completed]))
        let r = try #require(batch.requests.first)
        #expect(batch.requests.count == 1)
        #expect(r.success)
        #expect(r.model == "gpt-6-astra")
        #expect(r.inputTokens == 17957)
        #expect(r.cacheReadTokens == 17664)
        #expect(r.uncachedInputTokens == 293)
        #expect(r.outputTokens == 220)
        #expect(r.ttftMs == 2737)
        #expect(abs(r.durationMs - 9358) < 1)   // 46.290 (sent) → 55.648 (completed)
        #expect(r.sessionId == "conv-1")
        #expect(r.attributes["reasoning_token_count"] == "26")
        #expect(r.attributes["user.email"] == nil)
        #expect(r.attributes["user.account_id"] == nil)

        #expect(batch.prompts.map(\.text) == ["write about tides"])
        #expect(r.promptId == batch.prompts.first?.id)
    }

    @Test func requestAndResponseInSeparateBatches() throws {
        let parser = CodexOTLPParser()
        #expect(parser.parseBatch(logs([prompt, request])).requests.isEmpty)
        let r = try #require(parser.parseBatch(logs([completed])).requests.first)
        #expect(abs(r.durationMs - 9358) < 1)
        #expect(r.promptId != nil)
    }

    @Test func responseWithoutRequestHasNoDuration() throws {
        let r = try #require(CodexOTLPParser().parseBatch(logs([completed])).requests.first)
        #expect(r.durationMs == 0)
        #expect(r.genTokensPerSec == nil)
    }

    @Test func failedRequestIsRecorded() throws {
        let failed = (name: "codex.websocket_request", time: "2026-09-30T02:22:46.292Z", attrs: """
            ,{"key":"success","value":{"stringValue":"false"}},{"key":"error.message","value":{"stringValue":"stream closed"}}
            """)
        let r = try #require(CodexOTLPParser().parseBatch(logs([failed])).requests.first)
        #expect(!r.success)
        #expect(r.error == "stream closed")
    }

    @Test func ignoresNonResponseEndpointsAndClaudeCodeEvents() {
        let models = (name: "codex.api_request", time: "2026-09-30T02:22:39.000Z",
                      attrs: #",{"key":"endpoint","value":{"stringValue":"/models"}},{"key":"success","value":{"boolValue":false}}"#)
        #expect(CodexOTLPParser().parseBatch(logs([models])).requests.isEmpty)
        // Claude Code's parser ignores Codex's events, and Codex's ignores Claude Code's.
        #expect(OTLPParser.parseBatch(logs([prompt, request, completed])).requests.isEmpty)
        let claude = Data("""
            {"resourceLogs":[{"scopeLogs":[{"logRecords":[{"timeUnixNano":"1790017071589000000","attributes":[
              {"key":"event.name","value":{"stringValue":"api_request"}},
              {"key":"duration_ms","value":{"intValue":1000}},{"key":"output_tokens","value":{"intValue":50}}]}]}]}]}
            """.utf8)
        #expect(OTLPParser.parseBatch(claude).requests.count == 1)
        #expect(CodexOTLPParser().parseBatch(claude).requests.isEmpty)
    }

    @Test func codexLogUsesItsOwnDatabase() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = RequestLog(directory: dir, source: .codex)
        let batch = CodexOTLPParser().parseBatch(logs([prompt, request, completed]))
        log.record(batch.requests, prompts: batch.prompts)
        // A resent batch dedupes on the event timestamp.
        log.record(CodexOTLPParser().parseBatch(logs([completed])).requests, prompts: [])

        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("codex.sqlite").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("claude-code.sqlite").path))
        let reloaded = RequestLog(directory: dir, source: .codex)
        #expect(reloaded.totalCount == 1)
        #expect(reloaded.requests.first?.ttftMs == 2737)
        #expect(reloaded.promptText(for: reloaded.requests[0]) == "write about tides")
        let total = try #require(reloaded.database.stats(from: nil, to: nil, by: .total).first?.stats)
        #expect(total.requests == 1 && total.outputTokens == 220)
    }
}
