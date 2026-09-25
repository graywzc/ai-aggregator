import Foundation
import SQLite3

/// Aggregate figures for a set of requests, as SQLite sums them. Token and cost totals
/// count successful requests only; generation speed uses the same rule as the per-request
/// table (output tokens over the time after the first token, requests with TTFT and at
/// least `RequestSpeed.minOutputTokens` output tokens).
struct RequestStats: Equatable {
    var requests = 0
    var failures = 0
    var inputTokens = 0
    var outputTokens = 0
    var costUsd = 0.0
    /// Requests that reported a cost; side calls such as auto-mode classifiers report none.
    var costCount = 0
    var genTokens = 0
    var genMs = 0.0
    var ttftTotalMs = 0.0
    var ttftCount = 0

    var genTokensPerSec: Double? { genMs > 0 ? Double(genTokens) / (genMs / 1000) : nil }
    var averageTtftMs: Double? { ttftCount > 0 ? ttftTotalMs / Double(ttftCount) : nil }
    var averageOutputTokens: Double? { requests > 0 ? Double(outputTokens) / Double(requests) : nil }
    var reportedCostUsd: Double? { costCount > 0 ? costUsd : nil }
}

enum StatsGrouping {
    case total
    case model
    /// Calendar day in the local time zone, as `YYYY-MM-DD`.
    case day
}

/// SQLite store of every Claude Code request the app has seen, uncapped, so totals and
/// per-model figures can be asked for over any period. One serial queue guards the
/// connection, so any thread may call in.
final class RequestDatabase: @unchecked Sendable {
    /// Set when the on-disk database couldn't be opened and an in-memory one is standing in.
    private(set) var openError: String?

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.graywzc.AIAggregator.requestdb")

    /// `url` nil opens an in-memory database (tests).
    init(url: URL?) {
        if let url {
            switch Self.open(url.path) {
            case .success(let handle): db = handle
            case .failure(let error): openError = "\(url.lastPathComponent): \(error.message)"
            }
        }
        if db == nil, case .success(let handle) = Self.open(":memory:") { db = handle }
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
        exec(Self.schema)
    }

    deinit { sqlite3_close_v2(db) }

    // MARK: - Requests

    /// Folds `incoming` into the stored rows (a request reported by both its log event and
    /// its span arrives as two records) and returns the rows that changed, merged.
    func merge(_ incoming: [RequestSpeed]) -> [RequestSpeed] {
        guard !incoming.isEmpty else { return [] }
        return queue.sync {
            exec("BEGIN")
            defer { exec("COMMIT") }
            var changed: [String: RequestSpeed] = [:]
            for r in incoming {
                let existing = changed[r.id] ?? request(id: r.id)
                let merged = existing.map { $0.merged(with: r) } ?? r
                guard merged != existing else { continue }
                changed[r.id] = merged
                run(Self.upsertRequest, Self.bindings(merged))
            }
            return Array(changed.values)
        }
    }

    /// The newest `limit` requests, oldest first.
    func recent(limit: Int) -> [RequestSpeed] {
        queue.sync {
            query("SELECT \(Self.columns) FROM requests ORDER BY date DESC, id LIMIT ?", [limit], Self.request).reversed()
        }
    }

    func count() -> Int {
        queue.sync { query("SELECT COUNT(*) FROM requests", []) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0 }
    }

    func deleteAll() {
        queue.sync {
            run("DELETE FROM requests", [])
            run("DELETE FROM prompts", [])
        }
    }

    // MARK: - Prompts

    func upsertPrompts(_ prompts: [PromptRecord]) {
        guard !prompts.isEmpty else { return }
        queue.sync {
            exec("BEGIN")
            for p in prompts {
                run("INSERT OR REPLACE INTO prompts (id, text, date) VALUES (?, ?, ?)",
                    [p.id, p.text, p.date.timeIntervalSince1970])
            }
            exec("COMMIT")
        }
    }

    func prompts(ids: Set<String>) -> [PromptRecord] {
        guard !ids.isEmpty else { return [] }
        return queue.sync {
            let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
            return query("SELECT id, text, date FROM prompts WHERE id IN (\(marks))", Array(ids)) { stmt in
                PromptRecord(id: Self.text(stmt, 0) ?? "", text: Self.text(stmt, 1) ?? "",
                             date: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)))
            }
        }
    }

    // MARK: - Stats

    /// Aggregates over requests dated in `[from, to)`, grouped as asked. Model groups come
    /// biggest spender first; days newest first.
    func stats(from: Date?, to: Date?, by grouping: StatsGrouping) -> [(key: String, stats: RequestStats)] {
        var clauses: [String] = []
        var binds: [Any?] = []
        if let from { clauses.append("date >= ?"); binds.append(from.timeIntervalSince1970) }
        if let to { clauses.append("date < ?"); binds.append(to.timeIntervalSince1970) }
        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")

        let key: String, order: String
        switch grouping {
        case .total: key = "'all'"; order = "key"
        case .model: key = "model"; order = "cost DESC, requests DESC, key"
        case .day: key = "date(date, 'unixepoch', 'localtime')"; order = "key DESC"
        }
        let rated = "success AND ttft_ms IS NOT NULL AND duration_ms > ttft_ms AND output_tokens >= \(RequestSpeed.minOutputTokens)"
        let sql = """
            SELECT \(key) AS key,
                   SUM(success) AS requests,
                   SUM(1 - success),
                   SUM(CASE WHEN success THEN input_tokens ELSE 0 END),
                   SUM(CASE WHEN success THEN output_tokens ELSE 0 END),
                   COALESCE(SUM(CASE WHEN success THEN cost_usd END), 0) AS cost,
                   SUM(CASE WHEN success AND cost_usd IS NOT NULL THEN 1 ELSE 0 END),
                   COALESCE(SUM(CASE WHEN \(rated) THEN output_tokens END), 0),
                   COALESCE(SUM(CASE WHEN \(rated) THEN duration_ms - ttft_ms END), 0),
                   COALESCE(SUM(CASE WHEN success THEN ttft_ms END), 0),
                   SUM(CASE WHEN success AND ttft_ms IS NOT NULL THEN 1 ELSE 0 END)
            FROM requests \(whereSQL)
            GROUP BY key
            ORDER BY \(order)
            """
        return queue.sync {
            query(sql, binds) { stmt in
                var s = RequestStats()
                s.requests = Int(sqlite3_column_int64(stmt, 1))
                s.failures = Int(sqlite3_column_int64(stmt, 2))
                s.inputTokens = Int(sqlite3_column_int64(stmt, 3))
                s.outputTokens = Int(sqlite3_column_int64(stmt, 4))
                s.costUsd = sqlite3_column_double(stmt, 5)
                s.costCount = Int(sqlite3_column_int64(stmt, 6))
                s.genTokens = Int(sqlite3_column_int64(stmt, 7))
                s.genMs = sqlite3_column_double(stmt, 8)
                s.ttftTotalMs = sqlite3_column_double(stmt, 9)
                s.ttftCount = Int(sqlite3_column_int64(stmt, 10))
                return (Self.text(stmt, 0) ?? "", s)
            }
        }
    }

    // MARK: - Schema and row mapping

    private static let schema = """
        CREATE TABLE IF NOT EXISTS requests (
            id TEXT PRIMARY KEY,
            date REAL NOT NULL,
            model TEXT NOT NULL,
            success INTEGER NOT NULL,
            error TEXT,
            input_tokens INTEGER NOT NULL,
            output_tokens INTEGER NOT NULL,
            uncached_input_tokens INTEGER,
            cache_read_tokens INTEGER,
            cache_creation_tokens INTEGER,
            duration_ms REAL NOT NULL,
            ttft_ms REAL,
            cost_usd REAL,
            query_source TEXT,
            prompt_id TEXT,
            session_id TEXT,
            attempt INTEGER,
            attributes TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS requests_date ON requests(date);
        CREATE INDEX IF NOT EXISTS requests_model_date ON requests(model, date);
        CREATE TABLE IF NOT EXISTS prompts (
            id TEXT PRIMARY KEY,
            text TEXT NOT NULL,
            date REAL NOT NULL
        );
        """

    private static let columns = """
        id, date, model, success, error, input_tokens, output_tokens, uncached_input_tokens, \
        cache_read_tokens, cache_creation_tokens, duration_ms, ttft_ms, cost_usd, query_source, \
        prompt_id, session_id, attempt, attributes
        """

    private static let upsertRequest =
        "INSERT OR REPLACE INTO requests (\(columns)) VALUES (\(Array(repeating: "?", count: 18).joined(separator: ",")))"

    private static func bindings(_ r: RequestSpeed) -> [Any?] {
        [r.id, r.date.timeIntervalSince1970, r.model, r.success, r.error, r.inputTokens, r.outputTokens,
         r.uncachedInputTokens, r.cacheReadTokens, r.cacheCreationTokens, r.durationMs, r.ttftMs, r.costUsd,
         r.querySource, r.promptId, r.sessionId, r.attempt, encodeAttributes(r.attributes)]
    }

    private static func request(_ stmt: OpaquePointer) -> RequestSpeed {
        var r = RequestSpeed(
            id: text(stmt, 0) ?? "",
            model: text(stmt, 2) ?? "",
            inputTokens: Int(sqlite3_column_int64(stmt, 5)),
            outputTokens: Int(sqlite3_column_int64(stmt, 6)),
            durationMs: sqlite3_column_double(stmt, 10),
            ttftMs: double(stmt, 11),
            date: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)))
        r.success = sqlite3_column_int64(stmt, 3) != 0
        r.error = text(stmt, 4)
        r.uncachedInputTokens = int(stmt, 7)
        r.cacheReadTokens = int(stmt, 8)
        r.cacheCreationTokens = int(stmt, 9)
        r.costUsd = double(stmt, 12)
        r.querySource = text(stmt, 13)
        r.promptId = text(stmt, 14)
        r.sessionId = text(stmt, 15)
        r.attempt = int(stmt, 16)
        r.attributes = decodeAttributes(text(stmt, 17))
        return r
    }

    private func request(id: String) -> RequestSpeed? {
        query("SELECT \(Self.columns) FROM requests WHERE id = ?", [id], Self.request).first
    }

    private static func encodeAttributes(_ attributes: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: attributes, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func decodeAttributes(_ json: String?) -> [String: String] {
        guard let json, let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) else { return [:] }
        return object as? [String: String] ?? [:]
    }

    // MARK: - SQLite plumbing (call only on `queue`)

    private struct SQLiteError: Error { let message: String }

    private static func open(_ path: String) -> Result<OpaquePointer, SQLiteError> {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle { return .success(handle) }
        let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open failed"
        sqlite3_close_v2(handle)
        return .failure(SQLiteError(message: message))
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        var error: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &error)
        if rc != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errstr(rc))
            NSLog("RequestDatabase: %@ (%@)", message, sql.prefix(60).description)
            sqlite3_free(error)
        }
        return rc == SQLITE_OK
    }

    @discardableResult
    private func run(_ sql: String, _ binds: [Any?]) -> Bool {
        guard let stmt = prepare(sql, binds) else { return false }
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE && rc != SQLITE_ROW {
            NSLog("RequestDatabase: %@ (%@)", String(cString: sqlite3_errmsg(db)), sql.prefix(60).description)
            return false
        }
        return true
    }

    private func query<T>(_ sql: String, _ binds: [Any?], _ row: (OpaquePointer) -> T) -> [T] {
        guard let stmt = prepare(sql, binds) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(row(stmt)) }
        return out
    }

    private func prepare(_ sql: String, _ binds: [Any?]) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            NSLog("RequestDatabase: %@ (%@)", String(cString: sqlite3_errmsg(db)), sql.prefix(60).description)
            return nil
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, value) in binds.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case nil: sqlite3_bind_null(stmt, index)
            case let v as String: sqlite3_bind_text(stmt, index, v, -1, transient)
            case let v as Bool: sqlite3_bind_int64(stmt, index, v ? 1 : 0)
            case let v as Int: sqlite3_bind_int64(stmt, index, Int64(v))
            case let v as Double: sqlite3_bind_double(stmt, index, v)
            default: sqlite3_bind_text(stmt, index, "\(value!)", -1, transient)
            }
        }
        return stmt
    }

    private static func text(_ stmt: OpaquePointer, _ i: Int32) -> String? {
        guard sqlite3_column_type(stmt, i) != SQLITE_NULL, let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: c)
    }

    private static func double(_ stmt: OpaquePointer, _ i: Int32) -> Double? {
        sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, i)
    }

    private static func int(_ stmt: OpaquePointer, _ i: Int32) -> Int? {
        sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, i))
    }
}
