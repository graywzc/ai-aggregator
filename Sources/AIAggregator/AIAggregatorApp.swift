import SwiftUI
import AppKit

public struct AIAggregatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var usageService = UsageService.shared

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
        let parts = [usageService.chatGptCompact, usageService.claudeCompact, usageService.geminiCompact].compactMap { $0 }
        return parts.isEmpty ? "A" : parts.joined(separator: "  ")
    }
}

public final class AppDelegate: NSObject, NSApplicationDelegate {
    public override init() { super.init() }
    public func applicationDidFinishLaunching(_ notification: Notification) {}
}
