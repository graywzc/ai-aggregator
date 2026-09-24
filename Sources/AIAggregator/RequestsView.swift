import SwiftUI

/// Per-request table of Claude Code API calls, modeled on the aipc1 observer's
/// Recent Requests panel. Every column is a value Claude Code reports, except
/// Gen t/s, which is output tokens over the time after the first token.
struct RequestsView: View {
    @ObservedObject var log: RequestLog
    @State private var selection: RequestSpeed.ID?

    private var rows: [RequestSpeed] { log.requests.reversed() }   // newest first
    private var selected: RequestSpeed? { selection.flatMap { id in log.requests.first { $0.id == id } } }

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                summary
                table
            }
            .frame(minHeight: 260, idealHeight: 420)

            RequestDetail(request: selected, prompt: selected.flatMap(log.promptText))
                .frame(minHeight: 90, idealHeight: 160)
        }
        .frame(minWidth: 1250, minHeight: 500)
    }

    private var summary: some View {
        let ok = log.requests.filter(\.success)
        let failed = log.requests.count - ok.count
        let cost = ok.compactMap(\.costUsd).reduce(0, +)
        return HStack(spacing: 16) {
            Text("\(ok.count) completed")
            if failed > 0 { Text("\(failed) failed").foregroundColor(.orange) }
            Text("\(ok.reduce(0) { $0 + $1.inputTokens }.formatted()) in")
            Text("\(ok.reduce(0) { $0 + $1.outputTokens }.formatted()) out")
            Text("est. cost \(formatCost(cost))")
            Spacer()
            Button("Clear") { log.clear(); selection = nil }
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
                TableColumn("Model") { (r: RequestSpeed) in
                    Text(r.model.replacingOccurrences(of: "claude-", with: ""))
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
