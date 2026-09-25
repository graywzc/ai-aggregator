import SwiftUI

/// Periods the stats tab can total over, in the local calendar.
enum StatsPeriod: String, CaseIterable, Identifiable {
    case today = "Today"
    case yesterday = "Yesterday"
    case last7Days = "7 days"
    case last30Days = "30 days"
    case thisMonth = "This month"
    case all = "All time"

    var id: String { rawValue }

    /// Half-open `[from, to)`; nil bounds are unbounded.
    func range(now: Date = Date(), calendar: Calendar = .current) -> (from: Date?, to: Date?) {
        let today = calendar.startOfDay(for: now)
        func days(_ n: Int, from date: Date) -> Date { calendar.date(byAdding: .day, value: n, to: date) ?? date }
        switch self {
        case .today: return (today, nil)
        case .yesterday: return (days(-1, from: today), today)
        case .last7Days: return (days(-6, from: today), nil)
        case .last30Days: return (days(-29, from: today), nil)
        case .thisMonth:
            return (calendar.date(from: calendar.dateComponents([.year, .month], from: now)), nil)
        case .all: return (nil, nil)
        }
    }
}

struct StatsRow: Identifiable, Equatable {
    let key: String
    let stats: RequestStats
    var id: String { key }
}

struct StatsReport: Equatable {
    var total = RequestStats()
    var byModel: [StatsRow] = []
    var byDay: [StatsRow] = []

    static func build(from database: RequestDatabase, period: StatsPeriod) -> StatsReport {
        let range = period.range()
        func rows(_ grouping: StatsGrouping) -> [StatsRow] {
            database.stats(from: range.from, to: range.to, by: grouping).map { StatsRow(key: $0.key, stats: $0.stats) }
        }
        return StatsReport(total: rows(.total).first?.stats ?? RequestStats(), byModel: rows(.model), byDay: rows(.day))
    }
}

/// Totals, per-model and per-day breakdowns over a chosen period, computed by SQLite from
/// the full request history rather than the rows the table shows.
struct RequestStatsView: View {
    @ObservedObject var log: RequestLog
    @AppStorage("ClaudeCodeStatsPeriod") private var period: StatsPeriod = .today
    @State private var report: StatsReport?

    var body: some View {
        VStack(spacing: 0) {
            header
            VSplitView {
                StatsTable(title: "By model", keyTitle: "Model", rows: report?.byModel ?? [])
                    .frame(minHeight: 120, idealHeight: 200)
                StatsTable(title: "By day", keyTitle: "Day", rows: report?.byDay ?? [])
                    .frame(minHeight: 120)
            }
        }
        .task(id: "\(period.rawValue)#\(log.revision)") {
            let database = log.database
            let period = period
            report = await Task.detached { StatsReport.build(from: database, period: period) }.value
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: $period) {
                ForEach(StatsPeriod.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 520)

            if let total = report?.total {
                HStack(spacing: 16) {
                    Text("\(total.requests) completed")
                    if total.failures > 0 { Text("\(total.failures) failed").foregroundColor(.orange) }
                    Text("\(total.inputTokens.formatted()) in")
                    Text("\(total.outputTokens.formatted()) out")
                    Text("est. cost \(formatMoney(total.costUsd))")
                    Text("gen \(total.genTokensPerSec.map { "\(Int($0.rounded())) t/s" } ?? "–")")
                    Text("TTFT \(total.averageTtftMs.map(formatSecs) ?? "–")")
                    Spacer()
                    if let url = log.databaseURL {
                        Text(url.path).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                            .help("SQLite database; query it with the sqlite3 CLI")
                    }
                }
                .font(.system(size: 12, design: .monospaced))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
    }
}

private struct StatsTable: View {
    let title: String
    let keyTitle: String
    let rows: [StatsRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption).foregroundColor(.secondary).padding(.horizontal, 8).padding(.vertical, 4)
            Table(rows) {
                TableColumn(keyTitle) { (r: StatsRow) in
                    Text(r.key.replacingOccurrences(of: "claude-", with: ""))
                }
                .width(min: 100, ideal: 200, max: 320)
                TableColumn("Requests") { (r: StatsRow) in num(r.stats.requests) }.width(70)
                TableColumn("Failed") { (r: StatsRow) in
                    Text(r.stats.failures > 0 ? r.stats.failures.formatted() : "–")
                        .foregroundColor(r.stats.failures > 0 ? .orange : .primary)
                }
                .width(55)
                TableColumn("In") { (r: StatsRow) in num(r.stats.inputTokens) }.width(90)
                TableColumn("Out") { (r: StatsRow) in num(r.stats.outputTokens) }.width(80)
                TableColumn("Out/req") { (r: StatsRow) in
                    Text(r.stats.averageOutputTokens.map { String(Int($0.rounded())) } ?? "–")
                }
                .width(60)
                TableColumn("Cost") { (r: StatsRow) in Text(r.stats.reportedCostUsd.map(formatMoney) ?? "–") }.width(80)
                TableColumn("Gen t/s") { (r: StatsRow) in
                    Text(r.stats.genTokensPerSec.map { String(Int($0.rounded())) } ?? "–")
                }
                .width(60)
                TableColumn("TTFT") { (r: StatsRow) in Text(r.stats.averageTtftMs.map(formatSecs) ?? "–") }.width(55)
            }
            .font(.system(size: 11, design: .monospaced))
        }
    }

    private func num(_ n: Int) -> Text { Text(n.formatted()) }
}

private func formatSecs(_ ms: Double) -> String { String(format: "%.1fs", ms / 1000) }

/// Dollars with cents once the amount is big enough for cents to matter.
func formatMoney(_ usd: Double) -> String {
    usd >= 1 ? String(format: "$%.2f", usd) : String(format: "$%.4f", usd)
}
