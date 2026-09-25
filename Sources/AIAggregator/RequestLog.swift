import Foundation

/// Every Claude Code API request the app has seen, kept in a SQLite database so the
/// requests window survives restarts and stats can cover any period. The newest
/// `maxEntries` are also held in memory for the table view; the database is uncapped.
final class RequestLog: ObservableObject {
    static let maxEntries = 2000

    /// Newest last.
    @Published private(set) var requests: [RequestSpeed] = []
    /// Prompt text for the requests in memory, by `prompt.id`.
    @Published private(set) var prompts: [String: PromptRecord] = [:]
    /// Rows in the database, including those older than the in-memory window.
    @Published private(set) var totalCount = 0
    /// Bumped on every change, so stats views know when to re-query.
    @Published private(set) var revision = 0

    let database: RequestDatabase
    let databaseURL: URL?

    /// `directory` nil keeps everything in memory (tests).
    init(directory: URL?) {
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        databaseURL = directory?.appendingPathComponent("claude-code.sqlite")
        database = RequestDatabase(url: databaseURL)
        if let directory { Self.importLegacyFiles(in: directory, into: database) }
        load()
    }

    /// `~/Library/Application Support/AIAggregator`, or `$AIAGGREGATOR_DATA_DIR` when set so a
    /// development build can run beside the installed app without touching its data.
    static var defaultDirectory: URL? {
        if let override = ProcessInfo.processInfo.environment["AIAGGREGATOR_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AIAggregator", isDirectory: true)
    }

    func record(_ incoming: [RequestSpeed], prompts newPrompts: [PromptRecord]) {
        let changed = database.merge(incoming)
        let fresh = newPrompts.filter { prompts[$0.id] != $0 }
        database.upsertPrompts(fresh)
        guard !changed.isEmpty || !fresh.isEmpty else { return }

        for r in changed {
            if let i = requests.firstIndex(where: { $0.id == r.id }) {
                requests[i] = r
            } else {
                requests.append(r)
            }
        }
        requests.sort { $0.date < $1.date }
        if requests.count > Self.maxEntries { requests.removeFirst(requests.count - Self.maxEntries) }
        for p in fresh { prompts[p.id] = p }
        totalCount = database.count()
        revision += 1
    }

    func promptText(for request: RequestSpeed) -> String? {
        request.promptId.flatMap { prompts[$0]?.text }
    }

    /// Deletes every stored request and prompt.
    func clear() {
        database.deleteAll()
        requests = []
        prompts = [:]
        totalCount = 0
        revision += 1
    }

    private func load() {
        requests = database.recent(limit: Self.maxEntries)
        totalCount = database.count()
        prompts = Dictionary(uniqueKeysWithValues:
            database.prompts(ids: Set(requests.compactMap(\.promptId))).map { ($0.id, $0) })
    }

    // MARK: - Import of the JSONL files versions before 1.6 wrote

    static let legacyRequestsFile = "claude-code-requests.jsonl"
    static let legacyPromptsFile = "claude-code-prompts.jsonl"

    private static func importLegacyFiles(in directory: URL, into database: RequestDatabase) {
        let requestsURL = directory.appendingPathComponent(legacyRequestsFile)
        let promptsURL = directory.appendingPathComponent(legacyPromptsFile)
        let fm = FileManager.default
        guard fm.fileExists(atPath: requestsURL.path) || fm.fileExists(atPath: promptsURL.path) else { return }

        _ = database.merge(readLines(RequestSpeed.self, from: requestsURL))
        database.upsertPrompts(readLines(PromptRecord.self, from: promptsURL))
        for url in [requestsURL, promptsURL] where fm.fileExists(atPath: url.path) {
            try? fm.moveItem(at: url, to: url.appendingPathExtension("imported"))
        }
    }

    private static func readLines<T: Decodable>(_ type: T.Type, from url: URL) -> [T] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(T.self, from: Data($0)) }
    }
}
