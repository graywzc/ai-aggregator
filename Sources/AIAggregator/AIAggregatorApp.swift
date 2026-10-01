import SwiftUI
import AppKit

public struct AIAggregatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var usageService = UsageService.shared
    @ObservedObject private var speedStats = SpeedStatsService.shared
    @ObservedObject private var codexStats = SpeedStatsService.codex
    @ObservedObject private var visibility = ProvidersVisibility.shared

    public init() {}

    public var body: some Scene {
        MenuBarExtra {
            UsagePopoverView()
        } label: {
            Text(menuBarLabel)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarLabel: String {
        var parts: [String] = []
        if visibility.showChatGPTStats, let c = usageService.chatGptCompact { parts.append(c) }
        if visibility.showClaudeStats,  let c = usageService.claudeCompact  { parts.append(c) }
        if visibility.showClaudeCodeSpeed, let c = speedStats.compact       { parts.append(c) }
        if visibility.showCodexSpeed, let c = codexStats.compact           { parts.append("cx \(c)") }
        return parts.isEmpty ? "AA" : parts.joined(separator: "  ")
    }
}

public final class AppDelegate: NSObject, NSApplicationDelegate {
    public override init() { super.init() }
    public func applicationDidFinishLaunching(_ notification: Notification) {
        TelemetryListener.shared.start()
        // Lets a development build open straight to a requests window ("codex" for Codex's,
        // "turns" for the turns window).
        if let which = ProcessInfo.processInfo.environment["AIAGGREGATOR_SHOW_REQUESTS"] {
            if which == "turns" {
                WindowManager.shared.showTurnsWindow()
            } else {
                WindowManager.shared.showRequestsWindow(for: which == "codex" ? .codex : .claudeCode)
            }
        }
    }
}
