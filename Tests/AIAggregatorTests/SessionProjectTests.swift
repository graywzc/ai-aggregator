import Testing
import Foundation
@testable import AIAggregator

@Suite("Session projects")
struct SessionProjectTests {
    private static func tool(_ name: String, session: String = "s1", command: String? = nil, file: String? = nil) -> TraceSpan {
        var s = TraceSpan(id: UUID().uuidString, traceId: "t", parentId: "I", kind: .tool,
                          start: Date(timeIntervalSince1970: 1_790_000_000), end: Date(timeIntervalSince1970: 1_790_000_001))
        s.sessionId = session
        s.attributes["tool_name"] = name
        if let command { s.attributes["full_command"] = command }
        if let file { s.attributes["file_path"] = file }
        return s
    }

    @Test func cdTargetsNameTheProject() {
        let spans = [
            Self.tool("Bash", command: "cd /home/me/projects/app && swift build"),
            Self.tool("Bash", command: "ls; cd /home/me/projects/app/.claude/worktrees/feat/x && git status"),
            Self.tool("Read", file: "/home/me/projects/other/README.md"),
        ]
        let project = ProjectInference.infer(sessionId: "s1", spans: spans)
        #expect(project == SessionProject(sessionId: "s1", path: "/home/me/projects/app", source: .inferred))
        #expect(project?.name == "app")
        #expect(project?.slug == "-home-me-projects-app")
    }

    @Test func filesSharedDirectoryWhenNothingCds() {
        let spans = [
            Self.tool("Read", file: "/home/me/data/run-1/index.md"),
            Self.tool("Read", file: "/home/me/data/run-1/a.jpg"),
            Self.tool("Read", file: "/tmp/scratch/notes.txt"),
            Self.tool("Bash", command: "cat ~/.claude/settings.json; python3 /home/me/data/run-1/score.py"),
        ]
        #expect(ProjectInference.infer(sessionId: "s1", spans: spans)?.path == "/home/me/data/run-1")
    }

    @Test func scratchpadSlugMatchesAPathSeenLater() {
        let spans = [
            Self.tool("Write", file: "/tmp/claude-501/-Users-me-projects-live-trans/s1/scratchpad/plan.md"),
            Self.tool("Bash", command: "cat /Users/me/.claude/projects/-Users-me-projects-live-trans/memory/MEMORY.md"),
            Self.tool("Bash", command: "grep -rn foo /Users/me/projects/live-trans/Sources/App/Deep/File.swift"),
        ]
        let project = ProjectInference.infer(sessionId: "s1", spans: spans)
        #expect(project?.slug == "-Users-me-projects-live-trans")
        #expect(project?.path == "/Users/me/projects/live-trans")
        #expect(project?.name == "live-trans")

        // With no path spelling the slug, the slug itself is the name.
        let alone = ProjectInference.infer(sessionId: "s1", spans: Array(spans.prefix(2)))
        #expect(alone?.path == nil)
        #expect(alone?.name == "Users-me-projects-live-trans")
    }

    @Test func nothingUsableMeansNoProject() {
        let spans = [Self.tool("Bash", command: "git status && swift build"), Self.tool("Read", file: "/etc/hosts")]
        #expect(ProjectInference.infer(sessionId: "s1", spans: spans) == nil)
        #expect(ProjectInference.infer(sessionId: "s1", spans: []) == nil)
    }

    @Test func privateAndWorktreePathsFold() {
        #expect(ProjectInference.normalize("/private/tmp/x/") == "/tmp/x")
        #expect(ProjectInference.normalize("/Users/me/app/.codex/worktrees/task/sub") == "/Users/me/app")
        #expect(ProjectInference.name("/Users/me/app") == "app")
        #expect(ProjectInference.slug("/Users/me/.dot_files/x y") == "-Users-me--dot-files-x-y")
    }

    @Test func hookReportsAreExact() {
        let body = Data(#"{"session_id":"s9","cwd":"/home/me/app/.claude/worktrees/t","hook_event_name":"SessionStart","source":"startup"}"#.utf8)
        let project = ProjectInference.hookReport(body)
        #expect(project == SessionProject(sessionId: "s9", path: "/home/me/app", source: .hook))
        #expect(ProjectInference.hookReport(Data(#"{"resourceSpans":[]}"#.utf8)) == nil)
        #expect(ProjectInference.hookReport(Data(#"{"hook_event_name":"Stop","session_id":"s9"}"#.utf8)) == nil)
    }

    @Test func statsGroupByProjectAndHookOutranksInference() {
        let db = RequestDatabase(url: nil)
        db.insert(spans: [
            Self.tool("Bash", session: "s1", command: "cd /home/me/projects/app && make"),
            Self.tool("Bash", session: "s2", command: "cd /home/me/projects/web && npm test"),
        ])
        #expect(db.project(ofSession: "s1")?.name == "app")
        func request(_ id: String, session: String?, cost: Double) -> RequestSpeed {
            var r = RequestSpeed(id: id, model: "claude-opus-5-5", inputTokens: 10, outputTokens: 20, durationMs: 1000, ttftMs: 100,
                                 date: Date(timeIntervalSince1970: 1_790_000_000))
            r.success = true
            r.sessionId = session
            r.costUsd = cost
            return r
        }
        _ = db.merge([request("r1", session: "s1", cost: 1), request("r2", session: "s1", cost: 2),
                      request("r3", session: "s2", cost: 5), request("r4", session: nil, cost: 0.5)])
        var rows = db.stats(from: nil, to: nil, by: .project)
        #expect(rows.map(\.key) == ["web", "app", ""])
        #expect(rows.map(\.stats.requests) == [1, 2, 1])

        // The hook says s2 ran somewhere else; a later inference doesn't undo that.
        db.upsert(project: SessionProject(sessionId: "s2", path: "/srv/site", source: .hook))
        db.insert(spans: [Self.tool("Bash", session: "s2", command: "cd /home/me/projects/web && npm run build")])
        #expect(db.project(ofSession: "s2") == SessionProject(sessionId: "s2", path: "/srv/site", source: .hook))
        rows = db.stats(from: nil, to: nil, by: .project)
        #expect(rows.first?.key == "site")

        // A session that only named its scratchpad joins the project another session spelled out.
        db.insert(spans: [Self.tool("Write", session: "s3", file: "/tmp/claude-501/-home-me-projects-app/s3/scratchpad/x.md")])
        #expect(db.project(ofSession: "s3") == SessionProject(sessionId: "s3", path: "/home/me/projects/app", source: .inferred))
        _ = db.merge([request("r5", session: "s3", cost: 1)])
        #expect(db.stats(from: nil, to: nil, by: .project).first { $0.key == "app" }?.stats.requests == 3)

        db.deleteAll()
        #expect(db.project(ofSession: "s1") == nil)
    }

    @Test func worktreeSlugsFoldIntoTheRepository() {
        let project = SessionProject(sessionId: "s", path: nil, slug: "-home-me-app--claude-worktrees-feat-x", source: .inferred)
        #expect(project.slug == "-home-me-app")
        #expect(project.name == "home-me-app")
    }

    @Test func backfillCoversStoredSessionsOnce() {
        let db = RequestDatabase(url: nil)
        db.insert(spans: [Self.tool("Bash", session: "old", command: "cd /home/me/projects/legacy && ls")])
        db.deleteAll()
        // Spans stored by an earlier version arrived without inference; put one back directly.
        db.insert(spans: [Self.tool("Bash", session: "old", command: "cd /home/me/projects/legacy && ls")])
        db.backfillProjects()
        #expect(db.project(ofSession: "old")?.name == "legacy")
    }
}
