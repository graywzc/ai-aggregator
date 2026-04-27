import SwiftUI
import AppKit

public struct AIAggregatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var usageService = UsageService.shared
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
        if visibility.showGeminiStats,  let c = usageService.geminiCompact  { parts.append(c) }
        return parts.isEmpty ? "AA" : parts.joined(separator: "  ")
    }
}

public final class AppDelegate: NSObject, NSApplicationDelegate {
    public override init() { super.init() }
    public func applicationDidFinishLaunching(_ notification: Notification) {}
}
