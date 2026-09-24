import Foundation

/// Every Claude Code API request the app has seen, newest last, kept on disk as JSONL
/// so the requests window survives restarts. Lines are appended as events arrive; a
/// request reported by both its log event and its span appears twice and is folded
/// back together on load.
final class RequestLog: ObservableObject {
    static let maxEntries = 2000

    @Published private(set) var requests: [RequestSpeed] = []
    @Published private(set) var prompts: [String: PromptRecord] = [:]

    private let requestsURL: URL?
    private let promptsURL: URL?
    private let queue = DispatchQueue(label: "com.graywzc.AIAggregator.requestlog")

    /// `directory` nil keeps everything in memory (tests).
    init(directory: URL?) {
        requestsURL = directory?.appendingPathComponent("claude-code-requests.jsonl")
        promptsURL = directory?.appendingPathComponent("claude-code-prompts.jsonl")
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        load()
    }

    static var defaultDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AIAggregator", isDirectory: true)
    }

    func record(_ incoming: [RequestSpeed], prompts newPrompts: [PromptRecord]) {
        var changed: [RequestSpeed] = []
        for r in incoming {
            if let i = requests.firstIndex(where: { $0.id == r.id }) {
                let m = requests[i].merged(with: r)
                if m != requests[i] { requests[i] = m; changed.append(m) }
            } else {
                requests.append(r)
                changed.append(r)
            }
        }
        requests.sort { $0.date < $1.date }
        if requests.count > Self.maxEntries { requests.removeFirst(requests.count - Self.maxEntries) }

        let fresh = newPrompts.filter { prompts[$0.id] != $0 }
        for p in fresh { prompts[p.id] = p }

        append(changed, to: requestsURL)
        append(fresh, to: promptsURL)
    }

    func promptText(for request: RequestSpeed) -> String? {
        request.promptId.flatMap { prompts[$0]?.text }
    }

    func clear() {
        requests = []
        prompts = [:]
        queue.async { [requestsURL, promptsURL] in
            for url in [requestsURL, promptsURL].compactMap({ $0 }) { try? FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: - Persistence

    private func load() {
        var byId: [String: RequestSpeed] = [:]
        for r in Self.readLines(RequestSpeed.self, from: requestsURL) {
            byId[r.id] = byId[r.id].map { $0.merged(with: r) } ?? r
        }
        requests = Array(byId.values.sorted { $0.date < $1.date }.suffix(Self.maxEntries))

        let kept = Set(requests.compactMap(\.promptId))
        for p in Self.readLines(PromptRecord.self, from: promptsURL) where kept.contains(p.id) {
            prompts[p.id] = p
        }

        // Rewrite compacted files so duplicates and aged-out entries don't accumulate.
        rewrite(requests, to: requestsURL)
        rewrite(Array(prompts.values), to: promptsURL)
    }

    private static func readLines<T: Decodable>(_ type: T.Type, from url: URL?) -> [T] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(T.self, from: Data($0)) }
    }

    private static func encodeLines<T: Encodable>(_ items: [T]) -> Data {
        let encoder = JSONEncoder()
        var out = Data()
        for item in items {
            guard let line = try? encoder.encode(item) else { continue }
            out.append(line)
            out.append(UInt8(ascii: "\n"))
        }
        return out
    }

    private func append<T: Encodable>(_ items: [T], to url: URL?) {
        guard let url, !items.isEmpty else { return }
        let data = Self.encodeLines(items)
        queue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func rewrite<T: Encodable>(_ items: [T], to url: URL?) {
        guard let url else { return }
        let data = Self.encodeLines(items)
        queue.async { try? data.write(to: url, options: .atomic) }
    }
}
