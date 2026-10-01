import Foundation

/// One span of Claude Code's trace export (`OTEL_TRACES_EXPORTER=otlp` with
/// `CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1`). A turn is a `claude_code.interaction` span;
/// the model requests, tool calls and hooks it ran are its descendants.
struct TraceSpan: Identifiable, Equatable {
    enum Kind: String {
        case interaction
        case llmRequest = "llm_request"
        case tool
        /// The permission phase of a tool call: a rule, a hook, the auto-mode classifier or the user.
        case permission = "tool.blocked_on_user"
        case execution = "tool.execution"
        case hook
    }

    let id: String
    let traceId: String
    let parentId: String?
    let kind: Kind
    let start: Date
    let end: Date
    var sessionId: String? = nil
    /// The tailnet machine that sent it, nil for this Mac.
    var host: String? = nil
    /// Every attribute on the span, minus account identifiers and tool input/output content.
    var attributes: [String: String] = [:]

    /// The duration Claude Code reports, which it measures on a monotonic clock.
    var durationMs: Double {
        let key = kind == .interaction ? "interaction.duration_ms" : "duration_ms"
        return attributes[key].flatMap(Double.init) ?? end.timeIntervalSince(start) * 1000
    }
}

enum TraceSpanParser {
    /// Longest attribute value kept; a shell command can be a whole heredoc.
    static let maxValueLength = 2000
    /// Tool input and output content, sent only with detailed tracing on, and up to 60 KB each.
    private static let contentKeys: Set<String> = ["tool_input", "new_context"]

    static func parse(_ body: Data) -> [TraceSpan] {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return [] }
        var out: [TraceSpan] = []
        for resource in root["resourceSpans"] as? [[String: Any]] ?? [] {
            for scope in resource["scopeSpans"] as? [[String: Any]] ?? [] {
                for span in scope["spans"] as? [[String: Any]] ?? [] {
                    guard let name = span["name"] as? String, name.hasPrefix("claude_code."),
                          let kind = TraceSpan.Kind(rawValue: String(name.dropFirst("claude_code.".count))),
                          let id = span["spanId"] as? String, !id.isEmpty,
                          let start = OTLPParser.nanos(span["startTimeUnixNano"]),
                          let end = OTLPParser.nanos(span["endTimeUnixNano"]) else { continue }
                    let a = OTLPParser.attributes(span["attributes"])
                    let parent = span["parentSpanId"] as? String
                    var s = TraceSpan(id: id, traceId: span["traceId"] as? String ?? "",
                                      parentId: parent?.isEmpty == false ? parent : nil,
                                      kind: kind, start: start, end: max(start, end))
                    s.sessionId = a["session.id"] as? String
                    for (key, value) in a
                    where !OTLPParser.identityKeys.contains(key) && !contentKeys.contains(key) && key != "session.id" {
                        s.attributes[key] = String("\(value)".prefix(maxValueLength))
                    }
                    out.append(s)
                }
            }
        }
        return out
    }
}

// MARK: - What the time went on

/// The six things a turn's wall time is split between.
enum TimeGroup: String, CaseIterable, Identifiable {
    case model, tools, permission, user, hooks, overhead

    var id: String { rawValue }

    var label: String {
        switch self {
        case .model: return "Model"
        case .tools: return "Tools"
        case .permission: return "Permission checks"
        case .user: return "Waiting on you"
        case .hooks: return "Hooks"
        case .overhead: return "Claude Code"
        }
    }
}

/// What one step of a turn was doing. Tool calls are sorted by tool name, and shell
/// commands by the program they run.
enum Activity: String, CaseIterable {
    case model, build, test, install, git, search, file, shell, web, mcp, agent, otherTool
    case hook, permission, user, overhead

    var label: String {
        switch self {
        case .model: return "Model"
        case .build: return "Build"
        case .test: return "Test"
        case .install: return "Install"
        case .git: return "Git"
        case .search: return "Search"
        case .file: return "Files"
        case .shell: return "Shell"
        case .web: return "Web"
        case .mcp: return "MCP"
        case .agent: return "Subagent"
        case .otherTool: return "Other tool"
        case .hook: return "Hook"
        case .permission: return "Permission check"
        case .user: return "Waiting on you"
        case .overhead: return "Claude Code"
        }
    }

    var group: TimeGroup {
        switch self {
        case .model: return .model
        case .hook: return .hooks
        case .permission: return .permission
        case .user: return .user
        case .overhead: return .overhead
        default: return .tools
        }
    }

    /// Activity and comparison label for a tool call: the tool's name, or for a shell tool
    /// the program its command runs ("swift build") when Claude Code sent the command.
    static func of(tool: String, command: String?) -> (activity: Activity, label: String) {
        switch tool {
        case "Bash", "PowerShell":
            guard let command, !command.isEmpty else { return (.shell, tool) }
            return ShellCommand.classify(command)
        case "Grep", "Glob", "ToolSearch": return (.search, tool)
        case "Read", "Edit", "Write", "MultiEdit", "NotebookEdit": return (.file, tool)
        case "WebFetch", "WebSearch": return (.web, tool)
        case "Agent", "Task": return (.agent, tool)
        // These tools run for as long as the user takes to answer.
        case "AskUserQuestion", "ExitPlanMode": return (.user, tool)
        default:
            if tool.hasPrefix("mcp__") {
                let parts = tool.components(separatedBy: "__")
                return (.mcp, parts.count >= 3 ? "\(parts[1]): \(parts[2...].joined(separator: "__"))" : tool)
            }
            return (.otherTool, tool)
        }
    }
}

/// Sorts a shell command into build, test, install, git, search or plain shell by the
/// programs it runs. A compound command takes the heaviest kind among its parts, so
/// `cd app && swift test` is a test.
enum ShellCommand {
    static func classify(_ command: String) -> (activity: Activity, label: String) {
        // A heredoc body is input to a program, not commands.
        let script = command.range(of: "<<").map { String(command[..<$0.lowerBound]) } ?? command
        var best: (activity: Activity, label: String)?
        for segment in script.components(separatedBy: separators) {
            guard let found = classify(words: words(in: segment)) else { continue }
            if best == nil || rank(found.activity) > rank(best!.activity) { best = found }
        }
        return best ?? (.shell, "shell")
    }

    private static let separators = CharacterSet(charactersIn: "\n;|&")
    /// Words that only set up the command that follows them.
    private static let wrappers: Set<String> = ["sudo", "time", "env", "nohup", "command", "exec", "caffeinate", "nice", "xcrun"]
    private static let navigation: Set<String> = ["cd", "pushd", "popd", "export", "source", "set", "echo", "true", "sleep"]
    /// Programs whose first argument names what they do.
    private static let subcommandTools: Set<String> = [
        "swift", "git", "gh", "cargo", "go", "npm", "yarn", "pnpm", "bun", "brew", "pip", "pip3", "uv", "docker",
        "make", "kubectl", "dotnet", "poetry", "bundle", "apt", "apt-get",
    ]
    private static let testRunners: Set<String> = ["pytest", "jest", "vitest", "ctest", "tox", "rspec", "phpunit"]
    private static let testVerbHosts: Set<String> = [
        "swift", "cargo", "go", "npm", "yarn", "pnpm", "bun", "make", "mvn", "gradle", "gradlew", "dotnet", "mix", "rake",
    ]
    private static let builders: Set<String> = [
        "make", "cmake", "ninja", "xcodebuild", "tsc", "gcc", "g++", "cc", "clang", "clang++", "swiftc", "javac",
        "rustc", "webpack", "mvn", "gradle", "gradlew", "bazel", "meson",
    ]
    private static let buildVerbs: Set<String> = ["build", "check", "clippy", "vet", "compile"]
    private static let buildVerbHosts: Set<String> = [
        "swift", "cargo", "go", "dotnet", "docker", "npm", "yarn", "pnpm", "bun", "vite", "next",
    ]
    private static let installers: Set<String> = [
        "brew", "apt", "apt-get", "dnf", "yum", "pacman", "pip", "pip3", "pipx", "conda", "mamba", "gem", "pod",
        "npm", "yarn", "pnpm", "bun", "uv", "poetry", "cargo", "go", "bundle", "swift",
    ]
    private static let installVerbs: Set<String> = [
        "install", "i", "ci", "add", "upgrade", "update", "reinstall", "sync", "tap", "get", "resolve", "download",
    ]
    private static let searchers: Set<String> = ["grep", "egrep", "fgrep", "rg", "ag", "ack", "find", "fd", "locate", "mdfind"]

    private static func rank(_ activity: Activity) -> Int {
        switch activity {
        case .test: return 6
        case .build: return 5
        case .install: return 4
        case .git: return 3
        case .search: return 2
        default: return 1
        }
    }

    /// The segment's words from its program on, the program reduced to its file name.
    private static func words(in segment: String) -> [String] {
        var words = segment.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "()'\"`")) }
            .filter { !$0.isEmpty }
        while let first = words.first {
            let isAssignment = first.range(of: "^[A-Za-z_][A-Za-z0-9_]*=", options: .regularExpression) != nil
            if isAssignment || wrappers.contains(first) || first.hasPrefix("-") {
                words.removeFirst()
            } else if first == "timeout", words.count > 1 {
                words.removeFirst(2)
            } else if first == "ssh" {
                // `ssh host command…`: what counts is the command run over there.
                words.removeFirst()
                while let w = words.first, w.hasPrefix("-") { words.removeFirst(w.count == 2 ? min(2, words.count) : 1) }
                if !words.isEmpty { words.removeFirst() }
                if words.isEmpty { return ["ssh"] }
            } else {
                break
            }
        }
        if let first = words.first { words[0] = (first as NSString).lastPathComponent }
        return words
    }

    private static func classify(words: [String]) -> (activity: Activity, label: String)? {
        guard let program = words.first, !navigation.contains(program) else { return nil }
        let args = words.dropFirst().filter { !$0.hasPrefix("-") }
        let verb = args.first
        let head = Set(args.prefix(3))
        let label = subcommandTools.contains(program) && verb != nil ? "\(program) \(verb!)" : program

        let runsTests = testRunners.contains(program)
            || (testVerbHosts.contains(program) && (verb == "test" || verb == "check" && program == "make"))
            || (testVerbHosts.contains(program) && verb == "run" && args.dropFirst().first?.hasPrefix("test") == true)
            || (program.hasPrefix("python") && (head.contains("pytest") || head.contains("unittest")))
            || (program == "xcodebuild" && words.contains { $0 == "test" || $0 == "test-without-building" })
        if runsTests { return (.test, label) }
        if installers.contains(program), program != "swift" || verb == "package", !head.isDisjoint(with: installVerbs) {
            return (.install, label)
        }
        if builders.contains(program) || (buildVerbHosts.contains(program) && !head.isDisjoint(with: buildVerbs)) {
            return (.build, label)
        }
        if program == "git" || program == "gh" { return (.git, label) }
        if searchers.contains(program) { return (.search, label) }
        return (.shell, label)
    }
}

// MARK: - Turns

/// A model request, tool call or hook within a turn.
struct TurnStep: Identifiable, Equatable {
    let id: String
    let activity: Activity
    /// Model, tool or hook name.
    let title: String
    /// The shell command, when Claude Code sent it (`OTEL_LOG_TOOL_DETAILS=1`).
    let detail: String?
    /// What the comparison groups it under: the model, the tool, or a command's program.
    let label: String
    let start: Date
    let end: Date
    /// As Claude Code reports it. For a tool call this covers its permission phase too.
    let durationMs: Double
    /// Steps inside it: 0 at the top of the turn, more inside a subagent.
    let depth: Int
    let success: Bool
    /// A tool call's permission phase, and whether the user was the one deciding.
    var permission: DateInterval? = nil
    var permissionByUser = false
    /// A tool call's running time alone, when Claude Code reported it.
    var executionMs: Double? = nil
    var attributes: [String: String] = [:]

    /// Time spent doing the work: a tool call without its permission phase.
    var workMs: Double { executionMs ?? max(0, durationMs - (permission?.duration ?? 0) * 1000) }
}

/// One user prompt and everything Claude Code did to answer it.
struct Turn: Identifiable, Equatable {
    let id: String
    let start: Date
    let end: Date
    /// Wall time as Claude Code reports it.
    let wallMs: Double
    let host: String?
    let sessionId: String?
    /// The prompt, when Claude Code sent it (`OTEL_LOG_USER_PROMPTS=1`).
    let prompt: String?
    var steps: [TurnStep] = []
    /// Wall time by what the turn was waiting on at each moment, in milliseconds. Sums to
    /// the span's own length; time no step covers is Claude Code's own work.
    var time: [Activity: Double] = [:]

    func ms(_ group: TimeGroup) -> Double {
        time.reduce(0) { $1.key.group == group ? $0 + $1.value : $0 }
    }

    var requestCount: Int { steps.filter { $0.activity.group == .model }.count }
    var toolCount: Int { steps.filter { $0.activity.group == .tools || $0.activity == .user }.count }
}

enum TurnBuilder {
    /// Builds turns from spans, newest first. Spans may come in any order and from several
    /// traces; one whose turn isn't among them is left out.
    static func turns(from spans: [TraceSpan]) -> [Turn] {
        let byId = Dictionary(spans.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let interactions = spans.filter { $0.kind == .interaction }
        var members: [String: [(span: TraceSpan, ancestors: [TraceSpan])]] = [:]

        for span in spans where span.kind != .interaction {
            var ancestors: [TraceSpan] = []
            var turnId: String?
            var cursor = span.parentId
            while let id = cursor, let parent = byId[id], ancestors.count < 64 {
                if parent.kind == .interaction { turnId = parent.id; break }
                ancestors.append(parent)
                cursor = parent.parentId
            }
            // A span whose parent never arrived belongs to the turn that was running.
            turnId = turnId ?? interactions.first {
                $0.traceId == span.traceId && $0.sessionId == span.sessionId && $0.start <= span.start && span.start <= $0.end
            }?.id
            if let turnId { members[turnId, default: []].append((span, ancestors)) }
        }

        return interactions.map { turn(from: $0, members: members[$0.id] ?? []) }
            .sorted { $0.start > $1.start }
    }

    private static func turn(from root: TraceSpan, members: [(span: TraceSpan, ancestors: [TraceSpan])]) -> Turn {
        let prompt = root.attributes["user_prompt"].flatMap { $0 == "<REDACTED>" || $0.isEmpty ? nil : $0 }
        var turn = Turn(id: root.id, start: root.start, end: root.end, wallMs: root.durationMs,
                        host: root.host, sessionId: root.sessionId, prompt: prompt)

        let children = Dictionary(grouping: members.filter { $0.span.parentId != nil }, by: { $0.span.parentId! })
        var claims: [Claim] = []
        for (span, ancestors) in members {
            let depth = ancestors.filter { $0.kind == .tool || $0.kind == .llmRequest || $0.kind == .hook }.count
            let a = span.attributes
            var step: TurnStep?
            switch span.kind {
            case .llmRequest:
                // The auto-mode classifier is a model call made to decide a permission.
                let deciding = ancestors.contains { $0.kind == .permission }
                let model = ModelFilter.label(a["model"] ?? "")
                step = TurnStep(id: span.id, activity: deciding ? .permission : .model, title: model,
                                detail: a["query_source"], label: model, start: span.start, end: span.end,
                                durationMs: span.durationMs, depth: depth, success: a["success"] != "false")
            case .tool:
                let name = a["tool_name"] ?? "tool"
                let kind = Activity.of(tool: name, command: a["full_command"])
                let own = children[span.id]?.map(\.span) ?? []
                let execution = own.first { $0.kind == .execution }
                var s = TurnStep(id: span.id, activity: kind.activity, title: name,
                                 detail: a["full_command"] ?? a["skill_name"] ?? a["subagent_type"], label: kind.label,
                                 start: span.start, end: span.end, durationMs: span.durationMs, depth: depth,
                                 success: execution?.attributes["success"] != "false")
                s.executionMs = execution?.durationMs
                if let wait = own.first(where: { $0.kind == .permission }) {
                    s.permission = DateInterval(start: wait.start, end: wait.end)
                    s.permissionByUser = wait.attributes["source"]?.hasPrefix("user") == true
                }
                step = s
            case .hook:
                let name = a["hook_name"] ?? a["hook_event"] ?? "hook"
                step = TurnStep(id: span.id, activity: .hook, title: name, detail: nil, label: name,
                                start: span.start, end: span.end, durationMs: span.durationMs, depth: depth,
                                success: (a["num_blocking"].flatMap(Int.init) ?? 0) == 0)
            case .permission:
                let byUser = a["source"]?.hasPrefix("user") == true
                claims.append(Claim(span: span, activity: byUser ? .user : .permission, depth: ancestors.count))
            case .execution, .interaction:
                break
            }
            if var step {
                step.attributes = a
                turn.steps.append(step)
                claims.append(Claim(span: span, activity: step.activity, depth: ancestors.count))
            }
        }
        turn.steps.sort { ($0.start, $0.depth, $0.id) < ($1.start, $1.depth, $1.id) }
        turn.time = attribute(claims, from: root.start, to: root.end)
        return turn
    }

    /// A span's claim on the stretch of the turn it covers.
    private struct Claim {
        let start: Date
        let end: Date
        let activity: Activity
        let depth: Int

        init(span: TraceSpan, activity: Activity, depth: Int) {
            start = span.start
            end = span.end
            self.activity = activity
            self.depth = depth
        }
    }

    /// Splits `[from, to]` among the claims: each moment goes to the innermost span covering
    /// it (a subagent's model request over the Agent call around it), so parallel tool
    /// calls aren't counted twice and the parts sum to the whole. Unclaimed time is overhead.
    private static func attribute(_ claims: [Claim], from: Date, to: Date) -> [Activity: Double] {
        guard to > from else { return [:] }
        let clipped = claims.filter { $0.end > from && $0.start < to }
        let cuts = Set(clipped.flatMap { [max($0.start, from), min($0.end, to)] } + [from, to]).sorted()
        var time: [Activity: Double] = [:]
        for (a, b) in zip(cuts, cuts.dropFirst()) {
            let active = clipped.filter { $0.start <= a && $0.end >= b }
            let winner = active.max { ($0.depth, $0.start) < ($1.depth, $1.start) }
            time[winner?.activity ?? .overhead, default: 0] += b.timeIntervalSince(a) * 1000
        }
        return time
    }
}

// MARK: - Comparing machines

/// How long one kind of step took on one machine.
struct ActivityStat: Identifiable, Equatable {
    let activity: Activity
    let label: String
    let host: String
    var count = 0
    var totalMs = 0.0
    var medianMs = 0.0
    var p90Ms = 0.0
    var maxMs = 0.0

    var id: String { "\(activity.rawValue)|\(label)|\(host)" }
}

/// A machine's turns added up.
struct HostSummary: Identifiable, Equatable {
    let host: String
    var turns = 0
    var wallMs = 0.0
    var time: [TimeGroup: Double] = [:]

    var id: String { host }
}

struct TurnReport: Equatable {
    var hosts: [HostSummary] = []
    var activities: [ActivityStat] = []

    static func build(from turns: [Turn]) -> TurnReport {
        var hosts: [String: HostSummary] = [:]
        var samples: [String: (stat: ActivityStat, values: [Double])] = [:]
        for turn in turns {
            let host = HostName.label(turn.host)
            var summary = hosts[host] ?? HostSummary(host: host)
            summary.turns += 1
            summary.wallMs += turn.time.values.reduce(0, +)
            for group in TimeGroup.allCases { summary.time[group, default: 0] += turn.ms(group) }
            hosts[host] = summary

            for step in turn.steps {
                let stat = ActivityStat(activity: step.activity, label: step.label, host: host)
                samples[stat.id, default: (stat, [])].values.append(step.workMs)
            }
        }

        let order = Dictionary(uniqueKeysWithValues: Activity.allCases.enumerated().map { ($1, $0) })
        let activities = samples.values.map { entry -> ActivityStat in
            let sorted = entry.values.sorted()
            var stat = entry.stat
            stat.count = sorted.count
            stat.totalMs = sorted.reduce(0, +)
            stat.medianMs = percentile(sorted, 0.5)
            stat.p90Ms = percentile(sorted, 0.9)
            stat.maxMs = sorted.last ?? 0
            return stat
        }
        .sorted { (order[$0.activity] ?? 0, $0.label, $0.host) < (order[$1.activity] ?? 0, $1.label, $1.host) }
        return TurnReport(hosts: hosts.values.sorted { $0.wallMs > $1.wallMs }, activities: activities)
    }

    /// Nearest-rank percentile of an ascending list.
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1))]
    }
}
