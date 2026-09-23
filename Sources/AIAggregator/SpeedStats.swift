import Foundation

/// Timing of one Claude Code API request, as reported by its OpenTelemetry export.
struct RequestSpeed: Identifiable, Equatable {
    let id: String              // client_request_id when present, so logs and spans dedupe
    let model: String
    let inputTokens: Int        // uncached + cache reads + cache writes
    let outputTokens: Int
    let durationMs: Double
    let ttftMs: Double?
    let date: Date

    /// Requests this short finish before a rate means anything.
    static let minOutputTokens = 20

    /// Output tokens per second, measured after the first token when TTFT is known.
    var genTokensPerSec: Double? {
        guard outputTokens >= Self.minOutputTokens else { return nil }
        let ms = durationMs - (ttftMs ?? 0)
        guard ms > 0 else { return nil }
        return Double(outputTokens) / (ms / 1000)
    }
}

/// Decodes OTLP/HTTP JSON bodies (`OTEL_EXPORTER_OTLP_PROTOCOL=http/json`).
enum OTLPParser {
    static func parse(_ body: Data) -> [RequestSpeed] {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return [] }
        var out: [RequestSpeed] = []

        for resource in root["resourceSpans"] as? [[String: Any]] ?? [] {
            for scope in resource["scopeSpans"] as? [[String: Any]] ?? [] {
                for span in scope["spans"] as? [[String: Any]] ?? [] {
                    guard span["name"] as? String == "claude_code.llm_request" else { continue }
                    let a = attributes(span["attributes"])
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
                    guard a["event.name"] as? String == "api_request" else { continue }
                    let when = nanos(record["timeUnixNano"])
                    if let r = request(from: a, date: when, fallbackId: nil) { out.append(r) }
                }
            }
        }
        return out
    }

    private static func request(from a: [String: Any], date: Date?, fallbackId: String?) -> RequestSpeed? {
        guard let duration = number(a["duration_ms"]), let output = number(a["output_tokens"]) else { return nil }
        let input = (number(a["input_tokens"]) ?? 0)
            + (number(a["cache_read_tokens"]) ?? 0)
            + (number(a["cache_creation_tokens"]) ?? 0)
        let id = (a["client_request_id"] as? String) ?? fallbackId ?? UUID().uuidString
        return RequestSpeed(
            id: id,
            model: (a["model"] as? String) ?? "",
            inputTokens: Int(input),
            outputTokens: Int(output),
            durationMs: duration,
            ttftMs: number(a["ttft_ms"]),
            date: date ?? Date())
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
    static let shared = SpeedStatsService()

    /// Port Claude Code should export to: `OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:14318`.
    static let port: UInt16 = 14318
    static let maxRecent = 50

    @Published private(set) var recent: [RequestSpeed] = []   // newest last
    @Published private(set) var listenerError: String? = nil

    private var receiver: OTLPReceiver?

    func start() {
        guard receiver == nil else { return }
        let receiver = OTLPReceiver(port: Self.port) { [weak self] body in
            let requests = OTLPParser.parse(body)
            guard !requests.isEmpty else { return }
            DispatchQueue.main.async { self?.record(requests) }
        } onError: { [weak self] message in
            DispatchQueue.main.async { self?.listenerError = message }
        }
        self.receiver = receiver
        receiver.start()
    }

    /// Logs and spans describe the same request; keep one entry, preferring the one with TTFT.
    func record(_ requests: [RequestSpeed]) {
        for r in requests {
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
