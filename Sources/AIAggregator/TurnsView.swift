import AppKit
import SwiftUI

/// The Turns tab of the requests window: each prompt end to end, as the rounds of model requests and tool calls
/// Claude Code made to answer it, and how that time compares between machines. A turn still running is
/// listed too, its steps added as Claude Code reports them.
struct TurnsView: View {
    @ObservedObject var log: RequestLog
    @AppStorage("ClaudeCodeTurnsTab") private var tab: Tab = .turns
    @AppStorage("ClaudeCodeTurnsPeriod") private var period: StatsPeriod = .today
    @State private var host = TurnsView.allHosts
    @State private var search = ""
    @State private var loaded: [Turn]?

    enum Tab: String { case turns, compare }

    /// The most turns loaded for a period; older ones in it are left out.
    static let maxTurns = 1000
    private static let allHosts = ""

    private var hosts: [String] { Set((loaded ?? []).map { HostName.label($0.host) }).sorted() }
    private var turns: [Turn] {
        (loaded ?? []).filter { (host == Self.allHosts || HostName.label($0.host) == host) && $0.matches(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if loaded?.isEmpty == true {
                emptyState
            } else {
                switch tab {
                case .turns: TurnListView(turns: turns, database: log.database)
                // A running turn's steps so far would skew the medians.
                case .compare: TurnCompareView(report: TurnReport.build(from: (loaded ?? []).filter { !$0.running }))
                }
            }
        }
        .task(id: "\(period.rawValue)#\(log.spanRevision)") {
            let database = log.database
            let range = period.range()
            let limit = Self.maxTurns
            loaded = await Task.detached {
                var spans = database.turnSpans(from: range.from, to: range.to, limit: limit)
                // Only a period reaching to now has turns still running.
                guard range.to == nil else { return TurnBuilder.turns(from: spans) }
                let now = Date()
                spans += database.unfinishedSpans(since: now.addingTimeInterval(-TurnBuilder.runningWindow))
                return TurnBuilder.turns(from: spans, now: now)
            }.value
            if host != Self.allHosts, !hosts.contains(host) { host = Self.allHosts }
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Picker("", selection: $tab) {
                    Text("Turns").tag(Tab.turns)
                    Text("Compare").tag(Tab.compare)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                Picker("", selection: $period) {
                    ForEach(StatsPeriod.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 460)
                // Compare picks its own two hosts.
                if tab == .turns {
                    Picker("Host", selection: $host) {
                        Text("All hosts").tag(Self.allHosts)
                        ForEach(hosts, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(width: 170)
                    TextField("Find by command, tool or session", text: $search)
                        .textFieldStyle(.roundedBorder).frame(minWidth: 140, maxWidth: 260)
                        .help("Shows the turns whose prompt, session, host, or a step's tool, model or command has this text")
                }
                Spacer()
                if (loaded ?? []).count >= Self.maxTurns {
                    Text("newest \(Self.maxTurns.formatted()) turns").font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            TimeLegend()
        }
        .padding(8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No turns in this period").font(.headline)
            Text("""
                A turn shows up once its first step finishes. Turns come from Claude Code's trace export: \
                OTEL_TRACES_EXPORTER=otlp and CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1, in a session \
                started after this version was installed. See the README.
                """)
                .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Turns

private struct TurnListView: View {
    let turns: [Turn]
    let database: RequestDatabase
    @State private var selection: Turn.ID?

    private var selected: Turn? { turns.first { $0.id == selection } ?? turns.first }

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                summary
                table
            }
            .frame(minHeight: 180, idealHeight: 280)
            TurnTimeline(turn: selected, database: database)
                .frame(minHeight: 160, idealHeight: 340)
        }
    }

    private var summary: some View {
        let wall = turns.reduce(0.0) { $0 + $1.time.values.reduce(0, +) }
        let running = turns.filter(\.running).count
        return HStack(spacing: 16) {
            Text("\(turns.count) turns")
            if running > 0 { Text("\(running) running").foregroundColor(.green) }
            Text("\(formatSpan(wall)) end to end")
            ForEach(TimeGroup.allCases) { group in
                let ms = turns.reduce(0.0) { $0 + $1.ms(group) }
                if ms > 0 { Text("\(group.label.lowercased()) \(formatShare(ms, of: wall))").foregroundColor(.secondary) }
            }
            Spacer()
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.horizontal, 8).padding(.bottom, 6)
    }

    private var table: some View {
        Table(turns, selection: $selection) {
            Group {
                TableColumn("Started") { (t: Turn) in
                    HStack(spacing: 4) {
                        Text(t.start.formatted(.dateTime.month().day().hour().minute().second()))
                        if t.running { Circle().fill(Color.green).frame(width: 6, height: 6).help("Still running") }
                    }
                }
                .width(150)
                TableColumn("Host") { (t: Turn) in Text(HostName.label(t.host)) }.width(min: 50, ideal: 70)
                TableColumn("Session") { (t: Turn) in Text(t.sessionId.map { String($0.prefix(8)) } ?? "–") }.width(70)
                TableColumn("Prompt") { (t: Turn) in
                    Text(t.prompt?.replacingOccurrences(of: "\n", with: " ") ?? "–")
                        .foregroundColor(t.prompt == nil ? .secondary : .primary)
                        .help(t.prompt ?? "Set OTEL_LOG_USER_PROMPTS=1 to record prompt text")
                }
                .width(min: 120, ideal: 220)
                TableColumn("End to end") { (t: Turn) in
                    Ticking(active: t.running) { now in
                        Text(formatSpan(t.wallMs(at: now))).foregroundColor(t.running ? .green : .primary)
                    }
                }
                .width(80)
            }
            Group {
                TableColumn("Model") { (t: Turn) in ms(t.ms(.model)) }.width(60)
                TableColumn("Tools") { (t: Turn) in ms(t.ms(.tools)) }.width(60)
                TableColumn("Permission") { (t: Turn) in ms(t.ms(.permission)) }.width(80)
                TableColumn("You") { (t: Turn) in ms(t.ms(.user)) }.width(60)
                TableColumn("Hooks") { (t: Turn) in ms(t.ms(.hooks)) }.width(55)
                TableColumn("Claude Code") { (t: Turn) in ms(t.ms(.overhead)) }.width(90)
            }
            Group {
                TableColumn("Requests") { (t: Turn) in Text(t.requestCount.formatted()) }.width(70)
                TableColumn("Tool calls") { (t: Turn) in Text(t.toolCount.formatted()) }.width(75)
                TableColumn("Split") { (t: Turn) in
                    TimeSplitBar(parts: TimeGroup.allCases.map { ($0, t.ms($0)) }).frame(height: 10)
                }
                .width(min: 120, ideal: 220)
            }
        }
        .font(.system(size: 11, design: .monospaced))
    }

    private func ms(_ value: Double) -> Text { Text(value >= 1 ? formatSpan(value) : "–") }
}

/// The selected turn as a waterfall: one row per model request, tool call and hook, placed
/// on the turn's own time axis. A running turn's axis reaches to now, and its newest step
/// is kept in view. Clicking a row opens everything reported about that step beside it.
private struct TurnTimeline: View {
    let turn: Turn?
    let database: RequestDatabase
    @State private var selection: TurnStep.ID?

    private static let pendingId = "pending"

    var body: some View {
        if let turn {
            Ticking(active: turn.running) { now in
                VStack(alignment: .leading, spacing: 0) {
                    heading(turn, now: now)
                    Divider()
                    HSplitView {
                        steps(turn, now: now).frame(minWidth: 420)
                        if let step = turn.steps.first(where: { $0.id == selection }) {
                            StepDetail(step: step, turn: turn, now: now, database: database) { selection = nil }
                                .frame(minWidth: 300, idealWidth: 520)
                        }
                    }
                }
            }
        } else {
            Text("Select a turn to see its model requests and tool calls in order.")
                .font(.caption).foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func steps(_ turn: Turn, now: Date) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(turn.steps) { step in
                        StepRow(step: step, turn: turn, now: now)
                            .background(step.id == selection ? Color.accentColor.opacity(0.18) : Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture { selection = step.id == selection ? nil : step.id }
                        Divider().opacity(0.4)
                    }
                    // Between steps nothing says what is going on until it ends.
                    if turn.running, !turn.steps.contains(where: \.running) {
                        StepRow(step: Self.pending(after: turn), turn: turn, now: now, unreported: true)
                            .id(Self.pendingId)
                    }
                }
            }
            .onChange(of: turn.steps.count) { _ in
                guard turn.running else { return }
                proxy.scrollTo(turn.steps.contains(where: \.running) ? turn.steps.last?.id : Self.pendingId,
                               anchor: .bottom)
            }
        }
    }

    /// The stretch since the last reported step.
    private static func pending(after turn: Turn) -> TurnStep {
        var step = TurnStep(id: pendingId, activity: .overhead, title: "next step",
                            detail: "Claude Code reports a step when it ends", label: "", start: turn.end, end: turn.end,
                            durationMs: 0, depth: 0, success: true)
        step.running = true
        return step
    }

    private func heading(_ turn: Turn, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let prompt = turn.prompt {
                Text(prompt.replacingOccurrences(of: "\n", with: " ")).lineLimit(2).textSelection(.enabled)
            }
            HStack(spacing: 14) {
                if turn.running {
                    Text("running, \(formatSpan(turn.wallMs(at: now))) so far").foregroundColor(.green)
                } else {
                    Text("\(formatSpan(turn.wallMs)) end to end")
                }
                ForEach(TimeGroup.allCases) { group in
                    let ms = turn.ms(group)
                    if ms >= 1 {
                        HStack(spacing: 4) {
                            Swatch(group: group)
                            Text("\(group.label) \(formatSpan(ms))").foregroundColor(.secondary)
                        }
                    }
                }
                Spacer()
                Text(turn.sessionId.map { "session \($0.prefix(8))" } ?? "").foregroundColor(.secondary)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(8)
    }
}

private struct StepRow: View {
    let step: TurnStep
    let turn: Turn
    /// The time it is, which is where a running turn and its running steps end.
    let now: Date
    /// The row is the wait for a step Claude Code hasn't reported yet.
    var unreported = false

    private var span: Double { max(turn.end(at: now).timeIntervalSince(turn.start), 0.001) }
    private var end: Date { step.running ? turn.end(at: now) : step.end }
    private var durationMs: Double { step.running ? end.timeIntervalSince(step.start) * 1000 : step.durationMs }

    var body: some View {
        HStack(spacing: 8) {
            Text("+" + formatSpan(step.start.timeIntervalSince(turn.start) * 1000))
                .foregroundColor(.secondary).frame(width: 64, alignment: .trailing)
            HStack(spacing: 5) {
                Swatch(group: step.activity.group).opacity(unreported ? 0 : 1)
                Text(step.title).lineLimit(1).foregroundColor(unreported ? .secondary : .primary)
                if !step.success { Text("failed").foregroundColor(.orange) }
                if step.running, !unreported { Text("running").foregroundColor(.green) }
            }
            .padding(.leading, CGFloat(step.depth) * 12)
            .frame(width: 190, alignment: .leading)
            Text(unreported ? "In progress" : step.activity.label)
                .lineLimit(1).foregroundColor(.secondary).frame(width: 120, alignment: .leading)
            Text(step.detail?.replacingOccurrences(of: "\n", with: " ") ?? "")
                .lineLimit(1).truncationMode(.tail).foregroundColor(.secondary)
                .frame(minWidth: 80, maxWidth: .infinity, alignment: .leading)
            Text(formatSpan(durationMs)).foregroundColor(step.running ? .green : .primary)
                .frame(width: 60, alignment: .trailing)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.primary.opacity(0.05))
                    bar(from: step.start, to: end, group: step.activity.group, width: geo.size.width)
                        .opacity(unreported ? 0.4 : 1)
                    if let wait = step.permission {
                        bar(from: wait.start, to: wait.end, group: step.permissionByUser ? .user : .permission,
                            width: geo.size.width)
                    }
                }
            }
            .frame(minWidth: 200, maxWidth: .infinity)
            .frame(height: 10)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .help(tooltip)
    }

    private func bar(from: Date, to: Date, group: TimeGroup, width: CGFloat) -> some View {
        let x = max(0, from.timeIntervalSince(turn.start) / span) * width
        let w = max(2, min(width - x, to.timeIntervalSince(from) / span * width))
        return RoundedRectangle(cornerRadius: 2).fill(group.color).frame(width: w).offset(x: x)
    }

    private var tooltip: String {
        var lines = ["\(step.title): \(formatSpan(durationMs))\(step.running ? " so far" : "")"]
        if let wait = step.permission {
            lines.append("\(step.permissionByUser ? "waiting on you" : "permission check") \(formatSpan(wait.duration * 1000))")
        }
        if let run = step.executionMs { lines.append("running \(formatSpan(run))") }
        if let detail = step.detail { lines.append(detail) }
        lines += step.reported.map { "\($0.key): \($0.value)" }
        if !unreported { lines.append("Click for the whole step") }
        return lines.joined(separator: "\n")
    }
}

private extension TurnStep {
    /// The attributes Claude Code sent that the row doesn't already show, by name.
    var reported: [(key: String, value: String)] {
        let skip: Set<String> = ["full_command", "span.type", "terminal.type", "tool_name", "duration_ms"]
        return attributes.filter { !skip.contains($0.key) }.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    var isToolCall: Bool { activity.group == .tools || activity == .user }
}

/// Everything Claude Code reported about one step: when it ran and for how long, its whole
/// command, and what it returned when Claude Code sends that (`OTEL_LOG_TOOL_CONTENT=1`).
private struct StepDetail: View {
    let step: TurnStep
    let turn: Turn
    let now: Date
    let database: RequestDatabase
    let close: () -> Void
    @State private var output: String?

    private var hasOutput: Bool { step.attributes["output_length"] != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Swatch(group: step.activity.group)
                Text(step.title).fontWeight(.semibold).lineLimit(1)
                Text(step.activity.label).foregroundColor(.secondary).lineLimit(1)
                if !step.success { Text("failed").foregroundColor(.orange) }
                if step.running { Text("running").foregroundColor(.green) }
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Close")
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    section("Time") { Text(times.joined(separator: "\n")) }
                    if let detail = step.detail {
                        section(step.attributes["full_command"] == nil ? "Detail" : "Command") { Text(detail) }
                    }
                    if step.isToolCall {
                        section("Output") {
                            if let output { Text(output) }
                            if let note = outputNote { Text(note).foregroundColor(.secondary) }
                        }
                    }
                    if !step.reported.isEmpty {
                        section("Reported by Claude Code") {
                            Text(step.reported.map { "\($0.key): \($0.value)" }.joined(separator: "\n"))
                        }
                    }
                }
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        // A running step's output comes with its end, under the same id.
        .task(id: "\(step.id)#\(step.attributes["output_length"] ?? "")") {
            let database = database
            let id = step.id
            output = hasOutput ? await Task.detached { database.output(ofSpan: id) }.value : nil
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
            content()
        }
    }

    private var times: [String] {
        let offset = formatSpan(step.start.timeIntervalSince(turn.start) * 1000)
        var lines = ["started \(step.start.formatted(.dateTime.hour().minute().second())), \(offset) into the turn"]
        if step.running {
            let soFar = turn.end(at: now).timeIntervalSince(step.start) * 1000
            lines.append("running for \(formatSpan(soFar))")
        } else {
            lines.append("took \(formatSpan(step.durationMs))")
        }
        if let wait = step.permission {
            lines.append("\(step.permissionByUser ? "waiting on you" : "permission check") \(formatSpan(wait.duration * 1000))")
        }
        if let run = step.executionMs { lines.append("ran for \(formatSpan(run))") }
        return lines
    }

    /// What to say about the output besides showing it: that it was cut, or why there is none.
    private var outputNote: String? {
        if step.running {
            return "Claude Code reports a tool call when it ends. Until then it sends nothing about it: "
                + "not its name, its command or what it has printed so far."
        }
        guard hasOutput else {
            return "None recorded. With OTEL_LOG_TOOL_CONTENT=1 in Claude Code's settings, Bash, Read, web and MCP "
                + "calls send what they returned when they end, and it is kept in the database. A call that failed "
                + "sends none."
        }
        if let kept = step.attributes["output_length"].flatMap(Int.init),
           let full = step.attributes["output_original_length"].flatMap(Int.init), full > kept {
            return "The first \(kept.formatted()) of \(full.formatted()) characters; Claude Code cut the rest."
        }
        return nil
    }
}

// MARK: - Compare

/// Machines side by side: where each one's turn time went, and how long the same kind of
/// step took on two of them.
private struct TurnCompareView: View {
    let report: TurnReport
    @AppStorage("ClaudeCodeTurnsCompareFirst") private var chosenFirst = ""
    @AppStorage("ClaudeCodeTurnsCompareSecond") private var chosenSecond = ""
    @AppStorage("ClaudeCodeTurnsCompareShared") private var sharedOnly = true

    private var hosts: [String] { report.hosts.map(\.host).sorted() }

    /// The two machines compared: the chosen ones while they have turns, otherwise this Mac
    /// and the busiest other machine.
    private var pair: (first: String, second: String) {
        let busiest = report.hosts.map(\.host)
        let first = busiest.contains(chosenFirst) ? chosenFirst
            : busiest.contains(HostName.local) ? HostName.local : busiest.first ?? HostName.local
        let others = busiest.filter { $0 != first }
        return (first, others.contains(chosenSecond) ? chosenSecond : others.first ?? "")
    }

    private var steps: [StepComparison] {
        let rows = report.comparison(of: pair.first, with: pair.second)
        return sharedOnly && !pair.second.isEmpty ? rows.filter { $0.first != nil && $0.second != nil } : rows
    }

    var body: some View {
        VSplitView {
            section("By host: share of end-to-end time") {
                Table(report.hosts) {
                    TableColumn("Host") { (h: HostSummary) in Text(h.host) }.width(min: 60, ideal: 90)
                    TableColumn("Turns") { (h: HostSummary) in Text(h.turns.formatted()) }.width(50)
                    TableColumn("End to end") { (h: HostSummary) in Text(formatSpan(h.wallMs)) }.width(80)
                    TableColumn("Model") { (h: HostSummary) in share(h, .model) }.width(105)
                    TableColumn("Tools") { (h: HostSummary) in share(h, .tools) }.width(105)
                    TableColumn("Permission") { (h: HostSummary) in share(h, .permission) }.width(105)
                    TableColumn("You") { (h: HostSummary) in share(h, .user) }.width(105)
                    TableColumn("Hooks") { (h: HostSummary) in share(h, .hooks) }.width(105)
                    TableColumn("Claude Code") { (h: HostSummary) in share(h, .overhead) }.width(105)
                    TableColumn("Split") { (h: HostSummary) in
                        TimeSplitBar(parts: TimeGroup.allCases.map { ($0, h.time[$0] ?? 0) }).frame(height: 10)
                    }
                    .width(min: 120, ideal: 220)
                }
            }
            .frame(minHeight: 90, idealHeight: 130, maxHeight: 240)

            VStack(alignment: .leading, spacing: 0) {
                stepControls
                stepTable.font(.system(size: 11, design: .monospaced))
            }
            .frame(minHeight: 200)
        }
    }

    private var stepControls: some View {
        let pair = pair
        return HStack(spacing: 6) {
            Text("By step: the same kind of step on")
            Picker("", selection: Binding(get: { pair.first }, set: { chosenFirst = $0 })) {
                ForEach(hosts, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().fixedSize()
            Text("and")
            Picker("", selection: Binding(get: { pair.second }, set: { chosenSecond = $0 })) {
                ForEach(hosts.filter { $0 != pair.first }, id: \.self) { Text($0).tag($0) }
                if pair.second.isEmpty { Text("no other host").tag("") }
            }
            .labelsHidden().fixedSize()
            Toggle("Only steps both ran", isOn: $sharedOnly).padding(.leading, 8).disabled(pair.second.isEmpty)
            Spacer()
            Text("tool calls without their permission phase")
        }
        .font(.caption).foregroundColor(.secondary).controlSize(.small)
        .padding(.horizontal, 8).padding(.vertical, 4)
    }

    private var stepTable: some View {
        let pair = pair
        let other = pair.second.isEmpty ? "other" : pair.second
        return Table(steps) {
            TableColumn("Kind") { (s: StepComparison) in
                HStack(spacing: 5) {
                    Swatch(group: s.activity.group)
                    Text(s.activity.label)
                }
            }
            .width(min: 90, ideal: 120)
            TableColumn("Step") { (s: StepComparison) in Text(s.label).help(s.label) }.width(min: 120, ideal: 220)
            TableColumn("\(pair.first) calls") { (s: StepComparison) in calls(s.first) }.width(min: 60, ideal: 80)
            TableColumn("\(pair.first) median") { (s: StepComparison) in median(s.first, against: s.second) }
                .width(min: 70, ideal: 90)
            TableColumn("\(pair.first) P90") { (s: StepComparison) in p90(s.first) }.width(min: 60, ideal: 80)
            TableColumn("\(other) calls") { (s: StepComparison) in calls(s.second) }.width(min: 60, ideal: 80)
            TableColumn("\(other) median") { (s: StepComparison) in median(s.second, against: s.first) }
                .width(min: 70, ideal: 90)
            TableColumn("\(other) P90") { (s: StepComparison) in p90(s.second) }.width(min: 60, ideal: 80)
            TableColumn("Faster") { (s: StepComparison) in Text(difference(s, pair)) }.width(min: 110, ideal: 160)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption).foregroundColor(.secondary).padding(.horizontal, 8).padding(.vertical, 4)
            content().font(.system(size: 11, design: .monospaced))
        }
    }

    private func calls(_ stat: ActivityStat?) -> Text {
        Text(stat.map { $0.count.formatted() } ?? "–").foregroundColor(stat == nil ? .secondary : .primary)
    }

    /// The median, bold on the machine where it is shorter.
    private func median(_ stat: ActivityStat?, against other: ActivityStat?) -> some View {
        let shorter = stat.flatMap { s in other.map { s.medianMs < $0.medianMs / TurnCompareView.sameWithin } } ?? false
        return Text(stat.map { formatSpan($0.medianMs) } ?? "–")
            .fontWeight(shorter ? .bold : .regular)
            .foregroundColor(stat == nil ? .secondary : .primary)
            .help(stat.map { "total \(formatSpan($0.totalMs)), longest \(formatSpan($0.maxMs))" } ?? "")
    }

    private func p90(_ stat: ActivityStat?) -> Text {
        Text(stat.map { formatSpan($0.p90Ms) } ?? "–").foregroundColor(stat == nil ? .secondary : .primary)
    }

    /// Medians closer than this ratio read as the same.
    private static let sameWithin = 1.05

    /// Which machine's median is shorter, and by how many times.
    private func difference(_ step: StepComparison, _ pair: (first: String, second: String)) -> String {
        guard let ratio = step.ratio else { return "–" }
        let times = max(ratio, 1 / ratio)
        if times < Self.sameWithin { return "about the same" }
        return "\(ratio > 1 ? pair.first : pair.second) \(String(format: times < 10 ? "%.1f" : "%.0f", times))× faster"
    }

    private func share(_ h: HostSummary, _ group: TimeGroup) -> Text {
        let ms = h.time[group] ?? 0
        return Text(ms >= 1 ? "\(formatSpan(ms)) \(formatShare(ms, of: h.wallMs))" : "–")
    }
}

// MARK: - Shared pieces

/// Draws its content once a second while `active`, handing it the time it is.
private struct Ticking<Content: View>: View {
    let active: Bool
    @ViewBuilder let content: (Date) -> Content

    var body: some View {
        if active {
            TimelineView(.periodic(from: .now, by: 1)) { content($0.date) }
        } else {
            content(Date())
        }
    }
}

private extension Turn {
    /// Where the turn ends: now while it runs. Another machine's clock can be ahead of this one.
    func end(at now: Date) -> Date { running ? max(now, end) : end }

    func wallMs(at now: Date) -> Double { running ? end(at: now).timeIntervalSince(start) * 1000 : wallMs }
}

/// One bar split by what the time went on.
private struct TimeSplitBar: View {
    let parts: [(group: TimeGroup, ms: Double)]

    var body: some View {
        let total = parts.reduce(0) { $0 + $1.ms }
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(parts.filter { $0.ms > 0 }, id: \.group) { part in
                    Rectangle().fill(part.group.color)
                        .frame(width: max(1, (geo.size.width - CGFloat(parts.count)) * part.ms / max(total, 1)))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 2))
        }
        .help(parts.filter { $0.ms >= 1 }
            .map { "\($0.group.label) \(formatSpan($0.ms)) \(formatShare($0.ms, of: total))" }.joined(separator: "\n"))
    }
}

private struct TimeLegend: View {
    var body: some View {
        HStack(spacing: 14) {
            ForEach(TimeGroup.allCases) { group in
                HStack(spacing: 4) {
                    Swatch(group: group)
                    Text(group.label)
                }
                .help(group.explanation)
            }
            Spacer()
        }
        .font(.system(size: 11)).foregroundColor(.secondary)
    }
}

private struct Swatch: View {
    let group: TimeGroup

    var body: some View {
        RoundedRectangle(cornerRadius: 2).fill(group.color).frame(width: 9, height: 9)
    }
}

extension TimeGroup {
    var explanation: String {
        switch self {
        case .model: return "Waiting on an API request, a subagent's included"
        case .tools: return "A tool running on the machine: builds, tests, searches, git, file reads and edits"
        case .permission:
            return "Deciding whether a tool may run: rules, hooks and the auto-mode classifier. Under the desktop app "
                + "Claude Code doesn't say who decided, so a permission prompt you answered counts here too"
        case .user: return "A question or plan waiting for your answer, and in terminal sessions a permission prompt"
        case .hooks: return "Your configured hooks running"
        case .overhead: return "The rest of the turn: Claude Code's own work between steps"
        }
    }

    /// One fixed color per group, a lighter step of the same hue on dark backgrounds.
    var color: Color {
        switch self {
        case .model: return Color(light: 0x2a78d6, dark: 0x3987e5)
        case .tools: return Color(light: 0xeb6834, dark: 0xd95926)
        case .permission: return Color(light: 0x1baf7a, dark: 0x199e70)
        case .user: return Color(light: 0xeda100, dark: 0xc98500)
        case .hooks: return Color(light: 0xe87ba4, dark: 0xd55181)
        case .overhead: return Color(light: 0x898781, dark: 0x898781)
        }
    }
}

private extension Color {
    init(light: Int, dark: Int) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                           blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        })
    }
}

/// A length of time at the precision its size calls for: 840ms, 12.3s, 4m 05s, 1h 02m.
func formatSpan(_ ms: Double) -> String {
    if ms < 1000 { return "\(Int(ms.rounded()))ms" }
    let seconds = ms / 1000
    if seconds < 60 { return String(format: "%.1fs", seconds) }
    let whole = Int(seconds.rounded())
    if whole < 3600 { return String(format: "%dm %02ds", whole / 60, whole % 60) }
    return String(format: "%dh %02dm", whole / 3600, whole % 3600 / 60)
}

private func formatShare(_ ms: Double, of total: Double) -> String {
    total > 0 ? "\(Int((ms / total * 100).rounded()))%" : "–"
}
