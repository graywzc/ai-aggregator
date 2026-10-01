import Testing
import Foundation
@testable import AIAggregator

@Suite("Turns")
@MainActor
struct TurnTelemetryTests {
    private static let t0 = 1_790_000_000.0

    /// One span as Claude Code's OTLP/HTTP JSON export writes it, times in seconds from `t0`.
    private static func span(_ name: String, id: String, parent: String?, _ start: Double, _ end: Double,
                             trace: String = "trace1", _ attributes: [String: Any] = [:]) -> [String: Any] {
        var all = attributes
        all["session.id"] = "session1"
        all["user.email"] = "someone@example.com"
        all["duration_ms"] = Int(((end - start) * 1000).rounded())
        let encoded: [[String: Any]] = all.map { key, value in
            switch value {
            case let v as Bool: return ["key": key, "value": ["boolValue": v]]
            case let v as Int: return ["key": key, "value": ["intValue": v]]
            default: return ["key": key, "value": ["stringValue": "\(value)"]]
            }
        }
        func nanos(_ seconds: Double) -> String { String(Int64(((t0 + seconds) * 1000).rounded()) * 1_000_000) }
        var s: [String: Any] = [
            "traceId": trace, "spanId": id, "name": "claude_code.\(name)",
            "startTimeUnixNano": nanos(start), "endTimeUnixNano": nanos(end), "attributes": encoded,
        ]
        if let parent { s["parentSpanId"] = parent }
        return s
    }

    private static func body(_ spans: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["resourceSpans": [["scopeSpans": [["spans": spans]]]]])
    }

    /// A turn with two model requests, a build that ran beside a file read, a push the user
    /// had to approve, and a hook.
    private static let turn: [[String: Any]] = [
        span("interaction", id: "I", parent: "root", 0, 20, ["user_prompt": "ship it", "interaction.duration_ms": 20_000]),
        span("llm_request", id: "L1", parent: "I", 0.5, 3.5, ["model": "claude-opus-5-5", "success": true, "output_tokens": 300]),
        span("tool", id: "T1", parent: "I", 3.6, 9.6, ["tool_name": "Bash", "full_command": "cd app && swift build"]),
        span("tool.blocked_on_user", id: "P1", parent: "T1", 3.6, 3.7, ["decision": "accept", "source": "config"]),
        span("tool.execution", id: "E1", parent: "T1", 3.7, 9.6, ["success": true]),
        span("tool", id: "T2", parent: "I", 3.7, 3.8, ["tool_name": "Read"]),
        span("tool", id: "T3", parent: "I", 10, 16, ["tool_name": "Bash", "full_command": "git push"]),
        span("tool.blocked_on_user", id: "P3", parent: "T3", 10, 14, ["decision": "accept", "source": "user_temporary"]),
        span("tool.execution", id: "E3", parent: "T3", 14, 16, ["success": false, "error": "rejected"]),
        span("llm_request", id: "L2", parent: "I", 16.2, 19.2, ["model": "claude-opus-5-5", "success": true]),
        span("hook", id: "H1", parent: "I", 19.3, 19.5, ["hook_name": "Stop", "num_blocking": "0"]),
    ]

    private func close(_ a: Double?, _ b: Double) -> Bool { abs((a ?? 0) - b) < 1 }

    @Test func parsesSpansWithoutIdentityOrContent() {
        var spans = Self.turn
        spans.append(Self.span("tool", id: "T9", parent: "I", 1, 2, ["tool_name": "Read", "tool_input": "[TOOL INPUT: Read]\n{}"]))
        spans.append(["name": "claude_code.bash.subprocess", "spanId": "X", "traceId": "trace1"])
        let parsed = TraceSpanParser.parse(Self.body(spans))

        #expect(parsed.count == Self.turn.count + 1)
        let root = parsed.first { $0.id == "I" }!
        #expect(root.kind == .interaction)
        #expect(root.sessionId == "session1")
        #expect(root.attributes["user.email"] == nil)
        #expect(root.durationMs == 20_000)
        #expect(close(root.end.timeIntervalSince(root.start) * 1000, 20_000))
        #expect(parsed.first { $0.id == "P3" }?.kind == .permission)
        #expect(parsed.first { $0.id == "T9" }?.attributes["tool_input"] == nil)
        #expect(parsed.first { $0.id == "E3" }?.attributes["success"] == "false")
    }

    @Test func splitsATurnsTimeByWhatItWaitedOn() {
        let turns = TurnBuilder.turns(from: TraceSpanParser.parse(Self.body(Self.turn)))
        #expect(turns.count == 1)
        let turn = turns[0]

        #expect(turn.prompt == "ship it")
        #expect(turn.wallMs == 20_000)
        #expect(turn.steps.map(\.id) == ["L1", "T1", "T2", "T3", "L2", "H1"])
        #expect(turn.steps.map(\.activity) == [.model, .build, .file, .git, .model, .hook])
        #expect(turn.requestCount == 2)
        #expect(turn.toolCount == 3)

        // The read ran beside the build, so its 0.1s isn't counted twice.
        #expect(close(turn.time[.model], 6000))
        #expect(close(turn.time[.build], 5800))
        #expect(close(turn.time[.file], 100))
        #expect(close(turn.time[.permission], 100))
        #expect(close(turn.time[.user], 4000))
        #expect(close(turn.time[.git], 2000))
        #expect(close(turn.time[.hook], 200))
        #expect(close(turn.time[.overhead], 1800))
        #expect(close(turn.time.values.reduce(0, +), 20_000))
        #expect(close(turn.ms(.tools), 7900))

        let push = turn.steps[3]
        #expect(push.label == "git push")
        #expect(push.detail == "git push")
        #expect(push.permissionByUser)
        #expect(close((push.permission?.duration ?? 0) * 1000, 4000))
        #expect(push.executionMs == 2000)
        #expect(push.workMs == 2000)
        #expect(!push.success)
        #expect(turn.steps[1].label == "swift build")
        #expect(!turn.steps[1].permissionByUser)
    }

    @Test func subagentAndClassifierRequestsGoToTheRightGroup() {
        let spans: [[String: Any]] = [
            Self.span("interaction", id: "I", parent: nil, 0, 10),
            Self.span("tool", id: "A", parent: "I", 1, 9, ["tool_name": "Agent", "subagent_type": "Explore"]),
            Self.span("llm_request", id: "AL", parent: "A", 2, 5, ["model": "claude-haiku-4-5"]),
            Self.span("tool", id: "AT", parent: "A", 5, 7, ["tool_name": "Grep"]),
            Self.span("tool.blocked_on_user", id: "AP", parent: "AT", 5, 6, ["source": "classifier"]),
            Self.span("llm_request", id: "APL", parent: "AP", 5.2, 5.8, ["model": "claude-haiku-4-5"]),
            // Its parent span never arrived; it still belongs to the turn running at the time.
            Self.span("tool", id: "O", parent: "missing", 9.2, 9.7, ["tool_name": "mcp__github__create_issue"]),
            Self.span("tool", id: "Z", parent: "missing", 30, 31, ["tool_name": "Read"]),
        ]
        let turn = TurnBuilder.turns(from: TraceSpanParser.parse(Self.body(spans)))[0]

        #expect(turn.steps.map(\.id) == ["A", "AL", "AT", "APL", "O"])
        #expect(turn.steps.map(\.depth) == [0, 1, 1, 2, 0])
        #expect(turn.steps[0].detail == "Explore")
        #expect(turn.steps[3].activity == .permission)
        #expect(turn.steps[4].label == "github: create_issue")
        #expect(close(turn.time[.model], 3000))
        #expect(close(turn.time[.permission], 1000))
        #expect(close(turn.time[.search], 1000))
        #expect(close(turn.time[.agent], 3000))
        #expect(close(turn.time[.mcp], 500))
        #expect(close(turn.time[.overhead], 1500))
    }

    @Test func sortsShellCommandsByTheProgramTheyRun() {
        func kind(_ command: String) -> String {
            let c = ShellCommand.classify(command)
            return "\(c.activity.rawValue): \(c.label)"
        }
        #expect(kind("swift build 2>&1 | tail -5") == "build: swift build")
        #expect(kind("cd /tmp/app && GUI_SCREEN=MG248 swift test --filter Turns") == "test: swift test")
        #expect(kind("xcodebuild -scheme App -destination 'platform=macOS' test") == "test: xcodebuild")
        #expect(kind("xcodebuild -scheme App build") == "build: xcodebuild")
        #expect(kind("make test") == "test: make test")
        #expect(kind("make") == "build: make")
        #expect(kind("python3 -m pytest -q tests/") == "test: python3")
        #expect(kind("npm run test:unit") == "test: npm run")
        #expect(kind("npm run build") == "build: npm run")
        #expect(kind("brew upgrade --cask aiaggregator") == "install: brew upgrade")
        #expect(kind("uv pip install torch") == "install: uv pip")
        #expect(kind("swift package resolve") == "install: swift package")
        #expect(kind("git status --short; git log -3") == "git: git status")
        #expect(kind("gh pr create --fill") == "git: gh pr")
        #expect(kind("/usr/bin/grep -rn TODO Sources | head") == "search: grep")
        #expect(kind("ssh -o BatchMode=yes aipc 'cargo build --release'") == "build: cargo build")
        #expect(kind("ls -la && cat README.md") == "shell: ls")
        #expect(kind("python3 - <<'EOF'\nimport git\nmake = 1\nEOF") == "shell: python3")
        #expect(kind("cd /tmp") == "shell: shell")
        // Quoted words stay whole, so an assignment with spaces isn't taken for a program.
        #expect(kind("sleep 6; DB=\"file:$HOME/Library/Application Support/x.sqlite?mode=ro\"; sqlite3 \"$DB\" \"select 1\"") == "shell: sqlite3")
        #expect(kind("grep -E \"make|git\" notes.txt") == "search: grep")
        #expect(kind("ssh aipc \"cd repo && git pull\"") == "git: git pull")
        #expect(kind("ssh aipc") == "shell: ssh")

        #expect(Activity.of(tool: "Bash", command: nil).activity == .shell)
        #expect(Activity.of(tool: "Grep", command: nil).activity == .search)
        #expect(Activity.of(tool: "AskUserQuestion", command: nil).activity == .user)
        #expect(Activity.of(tool: "Skill", command: nil).activity == .otherTool)
    }

    @Test func storesSpansAndLoadsTurnsByPeriod() {
        let log = RequestLog(directory: nil)
        var spans = TraceSpanParser.parse(Self.body(Self.turn))
        // A second turn a day later on another machine, its spans arriving child first.
        let later: [[String: Any]] = [
            Self.span("tool", id: "T1b", parent: "Ib", 86_401, 86_403, trace: "trace2",
                      ["tool_name": "Bash", "full_command": "swift build"]),
            Self.span("interaction", id: "Ib", parent: nil, 86_400, 86_410, trace: "trace2"),
        ]
        spans += TraceSpanParser.parse(Self.body(later)).map { var s = $0; s.host = "aipc"; return s }
        log.record(spans: spans)
        log.record(spans: spans)   // a repeated export changes nothing

        let db = log.database
        #expect(db.turnCount() == 2)
        let all = TurnBuilder.turns(from: db.turnSpans(from: nil, to: nil, limit: 10))
        #expect(all.map(\.id) == ["Ib", "I"])
        #expect(all[0].host == "aipc")
        #expect(all[1].steps.count == 6)
        #expect(all[1].steps[0].attributes["output_tokens"] == "300")

        let day2 = Date(timeIntervalSince1970: Self.t0 + 86_000)
        #expect(TurnBuilder.turns(from: db.turnSpans(from: day2, to: nil, limit: 10)).map(\.id) == ["Ib"])
        #expect(TurnBuilder.turns(from: db.turnSpans(from: nil, to: day2, limit: 10)).map(\.id) == ["I"])
        #expect(TurnBuilder.turns(from: db.turnSpans(from: nil, to: nil, limit: 1)).map(\.id) == ["Ib"])

        log.clear()
        #expect(db.turnCount() == 0)
    }

    @Test func comparesHosts() {
        func turn(_ n: Int, host: String?, build: Double) -> [TraceSpan] {
            let spans: [[String: Any]] = [
                Self.span("interaction", id: "I\(n)", parent: nil, 0, build + 4, trace: "t\(n)"),
                Self.span("llm_request", id: "L\(n)", parent: "I\(n)", 0, 4, trace: "t\(n)", ["model": "claude-opus-5-5"]),
                Self.span("tool", id: "T\(n)", parent: "I\(n)", 4, 4 + build, trace: "t\(n)",
                          ["tool_name": "Bash", "full_command": "swift build"]),
            ]
            return TraceSpanParser.parse(Self.body(spans)).map { var s = $0; s.host = host; return s }
        }
        let spans = turn(1, host: nil, build: 10) + turn(2, host: nil, build: 30) + turn(3, host: nil, build: 20)
            + turn(4, host: "aipc", build: 6)
        let report = TurnReport.build(from: TurnBuilder.turns(from: spans))

        #expect(report.hosts.map(\.host) == [HostName.local, "aipc"])
        #expect(report.hosts[0].turns == 3)
        #expect(close(report.hosts[0].wallMs, 72_000))
        #expect(close(report.hosts[0].time[.tools], 60_000))
        #expect(close(report.hosts[1].time[.model], 4000))

        let builds = report.activities.filter { $0.activity == .build }
        #expect(builds.map(\.label) == ["swift build", "swift build"])
        let local = builds.first { $0.host == HostName.local }!
        #expect(local.count == 3)
        #expect(close(local.medianMs, 20_000))
        #expect(close(local.p90Ms, 30_000))
        #expect(close(local.totalMs, 60_000))
        #expect(close(builds.first { $0.host == "aipc" }?.medianMs, 6000))
        #expect(report.activities.first?.activity == .model)
    }

    @Test func formatsSpans() {
        #expect(formatSpan(840) == "840ms")
        #expect(formatSpan(12_340) == "12.3s")
        #expect(formatSpan(245_000) == "4m 05s")
        #expect(formatSpan(3_725_000) == "1h 02m")
    }
}
