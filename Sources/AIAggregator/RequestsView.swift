import SwiftUI

/// The Claude Code requests window: the per-request table and the stats tab.
struct RequestsView: View {
    @ObservedObject var log: RequestLog
    @AppStorage("ClaudeCodeRequestsTab") private var tab: Tab = .requests

    enum Tab: String { case requests, stats }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Requests").tag(Tab.requests)
                Text("Stats").tag(Tab.stats)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)
            .padding(.top, 8)

            switch tab {
            case .requests: RequestTableView(log: log)
            case .stats: RequestStatsView(log: log)
            }
        }
        .frame(minWidth: 1250, minHeight: 500)
    }
}

/// Per-request table of Claude Code API calls, modeled on the aipc1 observer's
/// Recent Requests panel. Every column is a value Claude Code reports, except
/// Gen t/s, which is output tokens over the time after the first token.
struct RequestTableView: View {
    @ObservedObject var log: RequestLog
    @StateObject private var filter = ModelFilter()
    @State private var selection: RequestSpeed.ID?
    @State private var confirmingClear = false

    /// Marks the Model header so the click hook can tell it from other columns.
    static let modelHeaderMarker = "▾"

    private var shown: [RequestSpeed] { filter.apply(log.requests) }
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
            }
            .frame(minHeight: 260, idealHeight: 420)

            RequestDetail(request: selected, prompt: selected.flatMap(log.promptText))
                .frame(minHeight: 90, idealHeight: 160)
        }
        .onChange(of: filter.hidden) { hidden in
            // Drop a selection the filter hides, so the detail pane matches the table.
            if let selected, hidden.contains(selected.model) { selection = nil }
        }
    }

    private var modelHeader: String {
        let models = ModelFilter.models(in: log.requests)
        let visible = models.filter { filter.isShown($0.model) }.count
        let suffix = filter.isActive && visible < models.count ? " \(visible)/\(models.count)" : ""
        return "Model \(Self.modelHeaderMarker)\(suffix)"
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
            Text("est. cost \(formatMoney(cost))")
            if shown.count < log.requests.count {
                Text("\(shown.count.formatted()) of the last \(log.requests.count.formatted()) shown; click Model to change")
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
                TableColumn("Stop") { (r: RequestSpeed) in Text(r.attributes["stop_reason"] ?? "–") }
                    .width(min: 55, ideal: 70)
                TableColumn("Cost") { (r: RequestSpeed) in Text(r.costUsd.map(formatCost) ?? "–") }.width(65)
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
            Text("Select a request to see every attribute Claude Code reported for it.")
                .font(.caption).foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private func formatSecs(_ ms: Double) -> String { String(format: "%.1fs", ms / 1000) }
private func formatCost(_ usd: Double) -> String { String(format: "$%.4f", usd) }
