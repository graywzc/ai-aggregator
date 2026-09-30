import Foundation

/// Turns Codex's OTLP/HTTP JSON log export into per-request records.
///
/// Codex reports each model response as a `codex.sse_event` of kind `response.completed`
/// carrying its token counts and TTFT, but not how long the request took. That comes
/// from the request event logged just before it in the same conversation
/// (`codex.websocket_request`, or `codex.api_request` over HTTP): Total is the time
/// between the request going out and the response completing, both as Codex stamps them.
/// Those two events can land in different export batches, so the parser keeps the open
/// request of each conversation between calls. Not thread-safe; call from one queue.
final class CodexOTLPParser {
    /// When each conversation's in-flight request was sent.
    private var pendingStart: [String: Date] = [:]
    /// The prompt each conversation's requests belong to: the latest one it sent.
    private var currentPrompt: [String: String] = [:]

    func parseBatch(_ body: Data) -> (requests: [RequestSpeed], prompts: [PromptRecord]) {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return ([], []) }
        var records: [(a: [String: Any], time: Date?, stamp: String)] = []
        for resource in root["resourceLogs"] as? [[String: Any]] ?? [] {
            for scope in resource["scopeLogs"] as? [[String: Any]] ?? [] {
                for record in scope["logRecords"] as? [[String: Any]] ?? [] {
                    let a = OTLPParser.attributes(record["attributes"])
                    guard (a["event.name"] as? String)?.hasPrefix("codex.") == true else { continue }
                    let time = Self.date(a["event.timestamp"])
                        ?? OTLPParser.nanos(record["timeUnixNano"]) ?? OTLPParser.nanos(record["observedTimeUnixNano"])
                    // Stable across an exporter's retries of the same batch, so resends dedupe.
                    let stamp = (a["event.timestamp"] as? String)
                        ?? (record["observedTimeUnixNano"]).map { "\($0)" } ?? UUID().uuidString
                    records.append((a, time, stamp))
                }
            }
        }
        // Exporters batch in order, but sort anyway: a request must precede its response.
        records.sort { ($0.time ?? .distantPast) < ($1.time ?? .distantPast) }

        var out: [RequestSpeed] = []
        var prompts: [PromptRecord] = []
        for (a, time, stamp) in records {
            let conversation = (a["conversation.id"] as? String) ?? ""
            switch a["event.name"] as? String {
            case "codex.user_prompt":
                let id = "\(conversation)#\(stamp)"
                currentPrompt[conversation] = id
                // Codex sends the text only with `log_user_prompt = true` in its [otel] config.
                if let text = a["prompt"] as? String, !text.isEmpty, text != "[REDACTED]", text != "<REDACTED>" {
                    prompts.append(PromptRecord(id: id, text: text, date: time ?? Date()))
                }
            case "codex.websocket_request", "codex.api_request":
                if let endpoint = a["endpoint"] as? String, !endpoint.contains("responses") { continue }
                if Self.bool(a["success"]) == false {
                    out.append(failure(a, conversation: conversation, time: time, stamp: stamp))
                    pendingStart[conversation] = nil
                } else if let time {
                    // The event is logged once the request is sent (or, over HTTP, once
                    // headers arrive); duration_ms is how long that took.
                    pendingStart[conversation] = time.addingTimeInterval(-(OTLPParser.number(a["duration_ms"]) ?? 0) / 1000)
                }
            case "codex.sse_event":
                if let message = a["error.message"] as? String {
                    var r = failure(a, conversation: conversation, time: time, stamp: stamp)
                    r.error = message
                    out.append(r)
                    pendingStart[conversation] = nil
                } else if a["event.kind"] as? String == "response.completed" {
                    out.append(completed(a, conversation: conversation, time: time, stamp: stamp))
                }
            default:
                continue
            }
        }
        return (out, prompts)
    }

    private func completed(_ a: [String: Any], conversation: String, time: Date?, stamp: String) -> RequestSpeed {
        let end = time ?? Date()
        let start = pendingStart.removeValue(forKey: conversation)
        let input = OTLPParser.number(a["input_token_count"]).map { Int($0) } ?? 0
        let cached = OTLPParser.number(a["cached_token_count"]).map { Int($0) }
        var r = RequestSpeed(
            id: "\(conversation)#\(stamp)",
            model: (a["model"] as? String) ?? "",
            // OpenAI counts cached tokens inside input_tokens, and reasoning inside output_tokens.
            inputTokens: input,
            outputTokens: OTLPParser.number(a["output_token_count"]).map { Int($0) } ?? 0,
            durationMs: start.map { max(0, end.timeIntervalSince($0) * 1000) } ?? 0,
            ttftMs: OTLPParser.number(a["ttft_ms"]),
            date: end)
        r.cacheReadTokens = cached
        r.uncachedInputTokens = cached.map { max(0, input - $0) }
        r.cacheCreationTokens = OTLPParser.number(a["cache_write_token_count"]).map { Int($0) }
        fillDetails(&r, from: a, conversation: conversation)
        return r
    }

    private func failure(_ a: [String: Any], conversation: String, time: Date?, stamp: String) -> RequestSpeed {
        var r = RequestSpeed(
            id: "\(conversation)#\(stamp)#error",
            model: (a["model"] as? String) ?? "",
            inputTokens: 0, outputTokens: 0,
            durationMs: OTLPParser.number(a["duration_ms"]) ?? 0,
            ttftMs: nil, date: time ?? Date())
        r.success = false
        r.error = (a["error.message"] as? String)
            ?? (a["http.response.status_code"]).map { "HTTP \($0)" }
            ?? "error"
        fillDetails(&r, from: a, conversation: conversation)
        return r
    }

    /// Attributes that identify the account rather than describe the request.
    private static let identityKeys: Set<String> = ["user.email", "user.account_id"]

    private func fillDetails(_ r: inout RequestSpeed, from a: [String: Any], conversation: String) {
        r.sessionId = conversation.isEmpty ? nil : conversation
        r.promptId = currentPrompt[conversation]
        r.querySource = a["originator"] as? String
        r.attempt = OTLPParser.number(a["attempt"]).map { Int($0) }
        for (key, value) in a where !Self.identityKeys.contains(key) {
            r.attributes[key] = "\(value)"
        }
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let b = value as? Bool { return b }
        if let s = value as? String { return Bool(s) }
        return nil
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Codex stamps each event in `event.timestamp` (millisecond ISO 8601); the record's
    /// own time field is sometimes left at zero.
    private static func date(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        return isoFormatter.date(from: s)
    }
}
