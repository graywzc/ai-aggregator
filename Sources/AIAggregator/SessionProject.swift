import Foundation

/// The directory a Claude Code session worked in: its project. Claude Code's telemetry
/// never says where a session ran, so the project is either reported by a `SessionStart`
/// hook (`source` "hook", exact) or worked out from the paths in the session's tool calls
/// (`source` "inferred", see `ProjectInference`).
struct SessionProject: Equatable {
    enum Source: String {
        case hook
        case inferred
    }

    let sessionId: String
    /// The working directory, when known. A worktree under `.claude/worktrees` or
    /// `.codex/worktrees` is folded into its repository.
    var path: String?
    /// The directory as Claude Code spells it in `~/.claude/projects` and its scratchpad:
    /// every character but letters, digits and `-` replaced by `-`. Known even when
    /// the path isn't, from a scratchpad or memory path the session touched.
    var slug: String
    /// What the stats show: the last path component, or the slug without its leading `-`.
    var name: String
    var source: Source

    init(sessionId: String, path: String?, slug: String? = nil, source: Source) {
        self.sessionId = sessionId
        self.path = path
        self.slug = slug.map(ProjectInference.foldWorktree) ?? path.map(ProjectInference.slug) ?? ""
        self.name = path.map(ProjectInference.name) ?? String(self.slug.drop(while: { $0 == "-" }))
        self.source = source
    }
}

/// Where a session worked, from the paths its tool calls mention (`OTEL_LOG_TOOL_DETAILS=1`).
/// Each clue votes for a directory; the one with the most votes wins:
/// - `cd /some/dir` at the start of a shell command or after `&&`, `;`, `||`: 3 votes. Claude
///   Code resets the shell's directory between calls, so sessions `cd` to their project a lot.
/// - a scratchpad path (`/tmp/claude-<uid>/<slug>/<session>/…`) or a memory path
///   (`~/.claude/projects/<slug>/…`): 2 votes for the slug, which is the working directory's.
/// - the deepest directory holding every absolute file the session read, edited or named in
///   a command: one vote per file. Files under `/tmp`, `/var`, system folders and `~/.claude`
///   don't count.
enum ProjectInference {
    static let cdWeight = 3
    static let slugWeight = 2

    /// The session's project, or nil when its tool calls mention no usable path.
    static func infer(sessionId: String, spans: [TraceSpan]) -> SessionProject? {
        var votes: [Candidate: Int] = [:]
        var fileDirectories: [String] = []
        var seenDirectories: Set<String> = []
        for span in spans where span.kind == .tool {
            var paths: [String] = []
            if let command = span.attributes["full_command"] ?? span.attributes["command"] {
                for target in cdTargets(in: command) {
                    if let slug = scratchpadSlug(of: target) {
                        votes[.slug(slug), default: 0] += cdWeight
                    } else {
                        let directory = normalize(target)
                        seenDirectories.insert(directory)
                        if !isSkipped(directory) { votes[.path(directory), default: 0] += cdWeight }
                    }
                }
                paths += absolutePaths(in: command)
            }
            if let file = span.attributes["file_path"], file.hasPrefix("/") { paths.append(file) }
            for path in paths {
                if let slug = scratchpadSlug(of: path) ?? memorySlug(of: path) {
                    votes[.slug(slug), default: 0] += slugWeight
                    continue
                }
                let directory = normalize(path)
                seenDirectories.insert(parent(of: directory))
                if !isSkipped(directory) { fileDirectories.append(parent(of: directory)) }
            }
        }
        if let common = commonDirectory(of: fileDirectories), common.split(separator: "/").count >= 3 {
            votes[.path(common), default: 0] += fileDirectories.count
        }
        guard let winner = votes.max(by: { a, b in
            let (ka, kb) = (a.key.sortKey, b.key.sortKey)
            return (a.value, ka.0, ka.1, ka.2) < (b.value, kb.0, kb.1, kb.2)
        })?.key else { return nil }
        switch winner {
        case .path(let path):
            return SessionProject(sessionId: sessionId, path: path, source: .inferred)
        case .slug(let slug):
            // A slug can't be turned back into a path, but a directory the session touched, or
            // one of its ancestors, may spell it.
            let path = seenDirectories.lazy.flatMap(ancestors).first { Self.slug($0) == slug }
            return SessionProject(sessionId: sessionId, path: path, slug: slug, source: .inferred)
        }
    }

    /// `~/.claude/projects` spelling of a directory: letters, digits and `-` kept, the rest `-`.
    static func slug(_ path: String) -> String {
        String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") ? $0 : "-" })
    }

    /// A worktree's slug (`…--claude-worktrees-…`) folded into its repository's, like `normalize`.
    static func foldWorktree(_ slug: String) -> String {
        for marker in ["--claude-worktrees-", "--codex-worktrees-"] {
            if let range = slug.range(of: marker) { return String(slug[..<range.lowerBound]) }
        }
        return slug
    }

    /// The last path component; "/" for the root.
    static func name(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? "/"
    }

    // MARK: - Clues

    private enum Candidate: Hashable {
        case path(String)
        case slug(String)

        /// Breaks ties: a path over a slug, then the shorter spelling.
        var sortKey: (Int, Int, String) {
            switch self {
            case .path(let p): return (1, -p.count, p)
            case .slug(let s): return (0, -s.count, s)
            }
        }
    }

    private static let cdPattern = try! NSRegularExpression(pattern: #"(?:^|&&|;|\|\||\(|\{)\s*cd\s+(/[^\s;&|)}]+)"#)
    private static let absolutePattern = try! NSRegularExpression(pattern: #"(?<![\w@:.~$-])(/(?:[\w.@+-]+/)+[\w.@+-]+)"#)
    private static let scratchpadPattern = try! NSRegularExpression(
        pattern: #"^/(?:private/)?(?:tmp|var/folders/[^/]+/[^/]+/T)/claude-[^/]+/(-[A-Za-z0-9-]+)(?:/|$)"#)
    private static let memoryPattern = try! NSRegularExpression(pattern: #"/\.claude/projects/(-[A-Za-z0-9-]+)(?:/|$)"#)
    private static let worktreePattern = try! NSRegularExpression(pattern: #"^(.*)/\.(?:claude|codex)/worktrees/.*$"#)
    private static let skippedPattern = try! NSRegularExpression(
        pattern: #"^/(?:tmp|var|dev|proc|sys|etc|usr|bin|sbin|nix|opt/homebrew|System|Library|Applications)(?:/|$)|/\.(?:claude|cache|secrets|config)(?:/|$)"#)

    private static func matches(_ regex: NSRegularExpression, in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
    }

    static func cdTargets(in command: String) -> [String] { matches(cdPattern, in: command) }

    static func absolutePaths(in command: String) -> [String] { matches(absolutePattern, in: command) }

    static func scratchpadSlug(of path: String) -> String? { matches(scratchpadPattern, in: path).first }

    static func memorySlug(of path: String) -> String? { matches(memoryPattern, in: path).first }

    /// Drops a trailing slash and macOS's `/private` alias, and folds a worktree into its repository.
    static func normalize(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        if p.hasPrefix("/private/") { p = String(p.dropFirst("/private".count)) }
        if let repo = matches(worktreePattern, in: p).first, !repo.isEmpty { p = repo }
        return p
    }

    static func isSkipped(_ path: String) -> Bool {
        skippedPattern.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }

    private static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "/" }
        return slash == path.startIndex ? "/" : String(path[..<slash])
    }

    /// The directory and each of its ancestors but the root, deepest first.
    private static func ancestors(of directory: String) -> [String] {
        var out: [String] = []
        var current = directory
        while current.count > 1 {
            out.append(current)
            current = parent(of: current)
        }
        return out
    }

    /// The deepest directory that is every given directory or an ancestor of it.
    static func commonDirectory(of directories: [String]) -> String? {
        guard var common = directories.first.map({ $0.split(separator: "/").map(String.init) }) else { return nil }
        for directory in directories.dropFirst() {
            let parts = directory.split(separator: "/").map(String.init)
            let shared = zip(common, parts).prefix { $0 == $1 }.count
            common = Array(common.prefix(shared))
        }
        return "/" + common.joined(separator: "/")
    }

    // MARK: - Hook reports

    /// A `SessionStart` hook's input, posted to the receiver as is: `{"session_id": …, "cwd": …,
    /// "hook_event_name": "SessionStart", …}`. Nil for any other body.
    static func hookReport(_ body: Data) -> SessionProject? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              object["hook_event_name"] != nil,
              let sessionId = object["session_id"] as? String, !sessionId.isEmpty,
              let cwd = object["cwd"] as? String, cwd.hasPrefix("/") else { return nil }
        return SessionProject(sessionId: sessionId, path: normalize(cwd), source: .hook)
    }
}
