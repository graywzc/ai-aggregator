import Foundation

/// One Claude Code API request, as reported by its OpenTelemetry export.
struct RequestSpeed: Identifiable, Equatable, Codable {
    let id: String              // client_request_id when present, so logs and spans dedupe
    let model: String
    let inputTokens: Int        // uncached + cache reads + cache writes
    let outputTokens: Int
    let durationMs: Double
    let ttftMs: Double?
    let date: Date

    // Per-request details for the requests window, straight from the export.
    var success: Bool = true
    var error: String? = nil
    var uncachedInputTokens: Int? = nil
    var cacheReadTokens: Int? = nil
    var cacheCreationTokens: Int? = nil
    var costUsd: Double? = nil
    var querySource: String? = nil
    var promptId: String? = nil
    var sessionId: String? = nil
    var attempt: Int? = nil
    /// Every attribute on the event, minus account identifiers.
    var attributes: [String: String] = [:]

    /// Requests this short finish before a rate means anything.
    static let minOutputTokens = 20

    /// Output tokens per second, measured after the first token when TTFT is known.
    var genTokensPerSec: Double? {
        guard success, outputTokens >= Self.minOutputTokens else { return nil }
        let ms = durationMs - (ttftMs ?? 0)
        guard ms > 0 else { return nil }
        return Double(outputTokens) / (ms / 1000)
    }

    /// Logs and spans describe the same request with different attribute sets; keep
    /// whichever side reported each field.
    func merged(with other: RequestSpeed) -> RequestSpeed {
        var m = RequestSpeed(
            id: id, model: model.isEmpty ? other.model : model,
            inputTokens: max(inputTokens, other.inputTokens),
            outputTokens: max(outputTokens, other.outputTokens),
            durationMs: max(durationMs, other.durationMs),
            ttftMs: ttftMs ?? other.ttftMs, date: date)
        m.success = success && other.success
        m.error = error ?? other.error
        m.uncachedInputTokens = uncachedInputTokens ?? other.uncachedInputTokens
        m.cacheReadTokens = cacheReadTokens ?? other.cacheReadTokens
        m.cacheCreationTokens = cacheCreationTokens ?? other.cacheCreationTokens
        m.costUsd = costUsd ?? other.costUsd
        m.querySource = querySource ?? other.querySource
        m.promptId = promptId ?? other.promptId
        m.sessionId = sessionId ?? other.sessionId
        m.attempt = attempt ?? other.attempt
        m.attributes = other.attributes.merging(attributes) { mine, _ in mine }
        return m
    }
}

/// The text of a user prompt, which the requests it triggered share via `prompt.id`.
struct PromptRecord: Codable, Equatable {
    let id: String
    let text: String
    let date: Date
}

/// Decodes OTLP/HTTP JSON bodies (`OTEL_EXPORTER_OTLP_PROTOCOL=http/json`).
enum OTLPParser {
    static func parse(_ body: Data) -> [RequestSpeed] { parseBatch(body).requests }

    static func parseBatch(_ body: Data) -> (requests: [RequestSpeed], prompts: [PromptRecord]) {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return ([], []) }
        var out: [RequestSpeed] = []
        var prompts: [PromptRecord] = []

        for resource in root["resourceSpans"] as? [[String: Any]] ?? [] {
            for scope in resource["scopeSpans"] as? [[String: Any]] ?? [] {
                for span in scope["spans"] as? [[String: Any]] ?? [] {
                    guard span["name"] as? String == "claude_code.llm_request" else { continue }
                    let a = attributes(span["attributes"])
                    // Failures arrive as api_error log events, which carry the error detail.
                    if let success = a["success"] as? Bool, !success { continue }
                    let end = nanos(span["endTimeUnixNano"])
                    if let r = request(from: a, date: end, fallbackId: span["spanId"] as? String) { out.append(r) }
                }
            }
        }

        for resource in root["resourceLogs"] as? [[String: Any]] ?? [] {
            for scope in resource["scopeLogs"] as? [[String: Any]] ?? [] {
                for record in scope["logRecords"] as? [[String: Any]] ?? [] {
                    let a = attributes(record["attributes"])
                    let when = nanos(record["timeUnixNano"])
                    switch a["event.name"] as? String {
                    case "api_request":
                        if let r = request(from: a, date: when, fallbackId: nil) { out.append(r) }
                    case "api_error":
                        out.append(failure(from: a, date: when))
                    case "user_prompt":
                        // Claude Code sends "<REDACTED>" unless OTEL_LOG_USER_PROMPTS=1.
                        if let id = a["prompt.id"] as? String, let text = a["prompt"] as? String,
                           text != "<REDACTED>", !text.isEmpty {
                            prompts.append(PromptRecord(id: id, text: text, date: when ?? Date()))
                        }
                    default:
                        continue
                    }
                }
            }
        }
        return (out, prompts)
    }

    private static func request(from a: [String: Any], date: Date?, fallbackId: String?) -> RequestSpeed? {
        guard let duration = number(a["duration_ms"]), let output = number(a["output_tokens"]) else { return nil }
        let uncached = number(a["input_tokens"])
        let cacheRead = number(a["cache_read_tokens"])
        let cacheCreation = number(a["cache_creation_tokens"])
        let input = (uncached ?? 0) + (cacheRead ?? 0) + (cacheCreation ?? 0)
        let id = (a["client_request_id"] as? String) ?? fallbackId ?? UUID().uuidString
        var r = RequestSpeed(
            id: id,
            model: (a["model"] as? String) ?? "",
            inputTokens: Int(input),
            outputTokens: Int(output),
            durationMs: duration,
            ttftMs: number(a["ttft_ms"]),
            date: date ?? Date())
        r.uncachedInputTokens = uncached.map { Int($0) }
        r.cacheReadTokens = cacheRead.map { Int($0) }
        r.cacheCreationTokens = cacheCreation.map { Int($0) }
        fillDetails(&r, from: a)
        return r
    }

    /// A failed attempt. Retries of one request share its client_request_id, so each
    /// failure gets its own id and never replaces the attempt that finally succeeded.
    private static func failure(from a: [String: Any], date: Date?) -> RequestSpeed {
        let base = (a["client_request_id"] as? String) ?? UUID().uuidString
        let attempt = number(a["attempt"]).map { Int($0) }
        var r = RequestSpeed(
            id: "\(base)#error\(attempt.map(String.init) ?? "")",
            model: (a["model"] as? String) ?? "",
            inputTokens: 0, outputTokens: 0,
            durationMs: number(a["duration_ms"]) ?? 0,
            ttftMs: nil, date: date ?? Date())
        r.success = false
        r.error = (a["error"] as? String) ?? "error"
        fillDetails(&r, from: a)
        return r
    }

    /// Attributes that identify the account rather than describe the request.
    private static let identityKeys: Set<String> = [
        "user.id", "user.email", "user.account_uuid", "user.account_id", "organization.id",
    ]

    private static func fillDetails(_ r: inout RequestSpeed, from a: [String: Any]) {
        r.costUsd = number(a["cost_usd"])
        r.querySource = a["query_source"] as? String
        r.promptId = a["prompt.id"] as? String
        r.sessionId = a["session.id"] as? String
        r.attempt = r.attempt ?? number(a["attempt"]).map { Int($0) }
        for (key, value) in a where !identityKeys.contains(key) {
            r.attributes[key] = "\(value)"
        }
    }

    /// OTLP attributes are `[{key, value: {stringValue|intValue|doubleValue|boolValue: …}}]`.
    private static func attributes(_ raw: Any?) -> [String: Any] {
        var out: [String: Any] = [:]
        for kv in raw as? [[String: Any]] ?? [] {
            guard let key = kv["key"] as? String, let value = kv["value"] as? [String: Any] else { continue }
            if let v = value["boolValue"] as? Bool { out[key] = v }
            else if let v = value["stringValue"] ?? value["intValue"] ?? value["doubleValue"] { out[key] = v }
        }
        return out
    }

    /// intValue may arrive as a JSON number or, per the OTLP spec, a decimal string.
    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func nanos(_ value: Any?) -> Date? {
        guard let n = number(value), n > 0 else { return nil }
        return Date(timeIntervalSince1970: n / 1_000_000_000)
    }
}

final class SpeedStatsService: ObservableObject {
    static let shared = SpeedStatsService(log: RequestLog(directory: RequestLog.defaultDirectory))

    /// Port Claude Code should export to: `OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:14318`.
    static let port: UInt16 = 14318
    static let maxRecent = 50

    @Published private(set) var recent: [RequestSpeed] = []   // newest last
    @Published private(set) var listenerError: String? = nil

    /// Full per-request history for the requests window; `recent` feeds the popover.
    let log: RequestLog
    private var receiver: OTLPReceiver?

    init(log: RequestLog = RequestLog(directory: nil)) {
        self.log = log
        recent = Array(log.requests.filter(\.success).suffix(Self.maxRecent))
    }

    func start() {
        guard receiver == nil else { return }
        let receiver = OTLPReceiver(port: Self.port) { [weak self] body in
            let batch = OTLPParser.parseBatch(body)
            guard !batch.requests.isEmpty || !batch.prompts.isEmpty else { return }
            DispatchQueue.main.async {
                self?.log.record(batch.requests, prompts: batch.prompts)
                self?.record(batch.requests)
            }
        } onError: { [weak self] message in
            DispatchQueue.main.async { self?.listenerError = message }
        }
        self.receiver = receiver
        receiver.start()
    }

    /// Logs and spans describe the same request; keep one entry, preferring the one with TTFT.
    func record(_ requests: [RequestSpeed]) {
        for r in requests where r.success {
            if let i = recent.firstIndex(where: { $0.id == r.id }) {
                if recent[i].ttftMs == nil && r.ttftMs != nil { recent[i] = r }
            } else {
                recent.append(r)
            }
        }
        recent.sort { $0.date < $1.date }
        if recent.count > Self.maxRecent { recent.removeFirst(recent.count - Self.maxRecent) }
    }

    /// Most recent request long enough to have a meaningful generation rate. Prefers one
    /// with TTFT: a log event without it can land before its span, and without TTFT the
    /// generation rate counts the wait for the first token.
    var latest: RequestSpeed? {
        recent.last { $0.genTokensPerSec != nil && $0.ttftMs != nil }
            ?? recent.last { $0.genTokensPerSec != nil }
    }

    /// Total output tokens over total streaming time, so a short request with a near-zero
    /// window can't swamp the figure the way a mean of per-request rates lets it. Uses only
    /// requests with TTFT when there are any, since the rest also count the wait.
    var averageGenTokensPerSec: Double? {
        let rated = recent.filter { $0.genTokensPerSec != nil }
        let timed = rated.filter { $0.ttftMs != nil }
        let pool = timed.isEmpty ? rated : timed
        let ms = pool.reduce(0.0) { $0 + $1.durationMs - ($1.ttftMs ?? 0) }
        guard ms > 0 else { return nil }
        return Double(pool.reduce(0) { $0 + $1.outputTokens }) / (ms / 1000)
    }
    var averageTtftMs: Double? { Self.mean(recent.compactMap(\.ttftMs)) }

    /// Menu bar text: the average rate, which holds steadier than any single request.
    var compact: String? {
        guard let rate = averageGenTokensPerSec else { return nil }
        return "\(Int(rate.rounded()))t/s"
    }

    private static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}
