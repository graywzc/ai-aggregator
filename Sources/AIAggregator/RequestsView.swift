import SwiftUI

/// A coding agent's requests window: the per-request table and the stats tab.
struct RequestsView: View {
    @ObservedObject var log: RequestLog
    @AppStorage private var tab: Tab

    enum Tab: String { case requests, stats }

    init(log: RequestLog) {
        self.log = log
        _tab = AppStorage(wrappedValue: .requests, log.source.defaultsKey("RequestsTab"))
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Requests").tag(Tab.requests)
                Text("Stats").tag(Tab.stats)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .trailing) { TailnetToggle(listener: .shared).padding(.trailing, 8) }
            .padding(.top, 8)

            switch tab {
            case .requests: RequestTableView(log: log)
            case .stats: RequestStatsView(log: log)
            }
        }
        .frame(minWidth: 1330, minHeight: 500)
    }
}

/// Opt-in listening on this Mac's Tailscale address, for agents on the user's other machines.
private struct TailnetToggle: View {
    @ObservedObject var listener: TelemetryListener

    var body: some View {
        HStack(spacing: 6) {
            if listener.acceptTailnet {
                if let endpoint = listener.tailnetEndpoint {
                    Text("http://\(endpoint)").foregroundColor(.secondary).textSelection(.enabled)
                } else if let error = listener.tailnetError {
                    Text(error).foregroundColor(.orange)
                }
            }
            Toggle("Accept from tailnet", isOn: $listener.acceptTailnet)
                .toggleStyle(.switch).controlSize(.mini)
                .help("Also listen on this Mac's Tailscale address, so agents on your other machines can export here")
        }
        .font(.system(size: 11))
    }
}

/// Per-request table of a coding agent's API calls, modeled on the aipc1 observer's
/// Recent Requests panel. Every column is a value the agent reports, except Gen t/s,
/// which is output tokens over the time after the first token, and Codex's Total,
/// which is the time between its request and response-completed events.
struct RequestTableView: View {
    @ObservedObject var log: RequestLog
    @StateObject private var filter: ModelFilter
    @StateObject private var hostFilter: ModelFilter
    @State private var selection: RequestSpeed.ID?
    @State private var confirmingClear = false

    init(log: RequestLog) {
        self.log = log
        _filter = StateObject(wrappedValue: ModelFilter(source: log.source))
        _hostFilter = StateObject(wrappedValue: ModelFilter(source: log.source, field: .host))
    }

    /// Marks the Model header so the click hook can tell it from other columns.
    static let modelHeaderMarker = "▾"
    static let hostHeaderMarker = "▿"

    private var shown: [RequestSpeed] { hostFilter.apply(filter.apply(log.requests)) }
    private var rows: [RequestSpeed] { shown.reversed() }   // newest first
    private var selected: RequestSpeed? { selection.flatMap { id in log.requests.first { $0.id == id } } }

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                summary
                table
                    .background(HeaderClickPopover(marker: Self.modelHeaderMarker) {
                        ModelFilterPopover(filter: filter, log: log)
                    })
                    .background(HeaderClickPopover(marker: Self.hostHeaderMarker) {
                        ModelFilterPopover(filter: hostFilter, log: log)
                    })
            }
            .frame(minHeight: 260, idealHeight: 420)

            RequestDetail(request: selected, prompt: selected.flatMap(log.promptText), source: log.source)
                .frame(minHeight: 90, idealHeight: 160)
        }
        .onChange(of: filter.hidden) { hidden in
            // Drop a selection the filter hides, so the detail pane matches the table.
            if let selected, hidden.contains(selected.model) { selection = nil }
        }
        .onChange(of: hostFilter.hidden) { hidden in
            if let selected, hidden.contains(selected.host ?? "") { selection = nil }
        }
    }

    private var isCodex: Bool { log.source == .codex }

    private var modelHeader: String {
        let models = ModelFilter.models(in: log.requests)
        let visible = models.filter { filter.isShown($0.model) }.count
        let suffix = filter.isActive && visible < models.count ? " \(visible)/\(models.count)" : ""
        return "Model \(Self.modelHeaderMarker)\(suffix)"
    }

    private var hostHeader: String {
        let hosts = ModelFilter.models(in: log.requests, field: .host)
        let visible = hosts.filter { hostFilter.isShown($0.model) }.count
        let suffix = hostFilter.isActive && visible < hosts.count ? " \(visible)/\(hosts.count)" : ""
        return "Host \(Self.hostHeaderMarker)\(suffix)"
    }

    private var summary: some View {
        let shown = self.shown
        let ok = shown.filter(\.success)
        let failed = shown.count - ok.count
        let cost = ok.compactMap(\.costUsd).reduce(0, +)
        return HStack(spacing: 16) {
            Text("\(ok.count) completed")
            if failed > 0 { Text("\(failed) failed").foregroundColor(.orange) }
            Text("\(ok.reduce(0) { $0 + $1.inputTokens }.formatted()) in")
            Text("\(ok.reduce(0) { $0 + $1.outputTokens }.formatted()) out")
            if log.source.reportsCost { Text("est. cost \(formatMoney(cost))") }
            if shown.count < log.requests.count {
                Text("\(shown.count.formatted()) of the last \(log.requests.count.formatted()) shown; click Model or Host to change")
                    .foregroundColor(.secondary)
            } else if log.totalCount > log.requests.count {
                Text("showing the last \(log.requests.count.formatted()) of \(log.totalCount.formatted()); see Stats for totals")
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Clear…") { confirmingClear = true }
                .confirmationDialog("Delete all \(log.totalCount.formatted()) recorded requests?",
                                    isPresented: $confirmingClear, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) { log.clear(); selection = nil }
                } message: {
                    Text("This removes the whole history from the database, not just the rows shown.")
                }
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(8)
    }

    private var table: some View {
        Table(rows, selection: $selection) {
            Group {
                TableColumn("Status") { (r: RequestSpeed) in
                    Text(r.success ? "OK" : "ERR").foregroundColor(r.success ? .green : .orange)
                }
                .width(40)
                TableColumn("Time") { (r: RequestSpeed) in
                    Text(r.date.formatted(date: .omitted, time: .standard))
                }
                .width(80)
                TableColumn(hostHeader) { (r: RequestSpeed) in Text(HostName.label(r.host)) }
                    .width(min: 50, ideal: 70)
                TableColumn("Prompt") { (r: RequestSpeed) in
                    Text(promptLabel(r)).foregroundColor(log.promptText(for: r) == nil ? .secondary : .primary)
                        .help(log.promptText(for: r) ?? "")
                }
                .width(min: 100, ideal: 160)
                TableColumn(modelHeader) { (r: RequestSpeed) in
                    Text(ModelFilter.label(r.model))
                }
                .width(min: 70, ideal: 110)
                TableColumn("In") { (r: RequestSpeed) in num(r.success ? r.inputTokens : nil) }
                    .width(70)
            }
            Group {
                TableColumn("Uncached") { (r: RequestSpeed) in num(r.uncachedInputTokens) }.width(65)
                TableColumn("Cache R") { (r: RequestSpeed) in num(r.cacheReadTokens) }.width(70)
                TableColumn("Cache W") { (r: RequestSpeed) in num(r.cacheCreationTokens) }.width(65)
                TableColumn("TTFT") { (r: RequestSpeed) in Text(r.ttftMs.map(formatSecs) ?? "–") }.width(50)
                TableColumn("Out") { (r: RequestSpeed) in num(r.success ? r.outputTokens : nil) }
                    .width(55)
            }
            Group {
                TableColumn("Gen t/s") { (r: RequestSpeed) in
                    Text(r.genTokensPerSec.map { String(Int($0.rounded())) } ?? "–")
                }
                .width(55)
                TableColumn("Total") { (r: RequestSpeed) in Text(formatSecs(r.durationMs)) }
                    .width(55)
                // Codex reports no stop reason or cost; those slots show its reasoning
                // tokens (counted within Out) and effort instead.
                TableColumn(isCodex ? "Reason" : "Stop") { (r: RequestSpeed) in
                    Text((isCodex ? r.attributes["reasoning_token_count"] : r.attributes["stop_reason"]) ?? "–")
                }
                .width(min: 55, ideal: 70)
                TableColumn(isCodex ? "Effort" : "Cost") { (r: RequestSpeed) in
                    Text(isCodex ? r.attributes["model_reasoning_effort"] ?? "–" : r.costUsd.map(formatCost) ?? "–")
                }
                .width(65)
            }
        }
        .font(.system(size: 11, design: .monospaced))
    }

    private func promptLabel(_ r: RequestSpeed) -> String {
        if let text = log.promptText(for: r) {
            return text.replacingOccurrences(of: "\n", with: " ")
        }
        // Side calls like the auto-mode classifier only carry query_source_safe.
        return r.querySource ?? r.attributes["query_source_safe"] ?? r.attributes["llm_request.context"] ?? "–"
    }

    private func num(_ n: Int?) -> Text { Text(n.map { $0.formatted() } ?? "–") }
}

private struct RequestDetail: View {
    let request: RequestSpeed?
    let prompt: String?
    let source: RequestSource

    var body: some View {
        if let request {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let error = request.error {
                        Text(error).foregroundColor(.orange).textSelection(.enabled)
                    }
                    if let prompt {
                        Text(prompt).textSelection(.enabled)
                        Divider()
                    }
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 2) {
                        ForEach(request.attributes.sorted { $0.key < $1.key }, id: \.key) { kv in
                            GridRow {
                                Text(kv.key).foregroundColor(.secondary)
                                Text(kv.value).textSelection(.enabled)
                            }
                        }
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
        } else {
            Text("Select a request to see every attribute \(source.name) reported for it.")
                .font(.caption).foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private func formatSecs(_ ms: Double) -> String { String(format: "%.1fs", ms / 1000) }
private func formatCost(_ usd: Double) -> String { String(format: "$%.4f", usd) }
