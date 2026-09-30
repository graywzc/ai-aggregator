import Foundation

/// A coding agent whose API requests the app records from its OpenTelemetry export. Each
/// has its own database, window and saved view settings; the table and stats are shared.
enum RequestSource: String, CaseIterable {
    case claudeCode
    /// OpenAI's Codex, the coding agent in the ChatGPT app and the `codex` CLI.
    case codex

    var name: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    var databaseFileName: String {
        switch self {
        case .claudeCode: return "claude-code.sqlite"
        case .codex: return "codex.sqlite"
        }
    }

    /// Codex reports no cost, so its window leaves the cost figures out.
    var reportsCost: Bool { self == .claudeCode }

    /// UserDefaults key for a per-window setting. Claude Code keeps the keys it had
    /// before Codex was added, so existing choices carry over.
    func defaultsKey(_ name: String) -> String {
        switch self {
        case .claudeCode: return "ClaudeCode\(name)"
        case .codex: return "Codex\(name)"
        }
    }
}
