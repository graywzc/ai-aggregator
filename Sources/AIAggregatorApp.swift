import SwiftUI
import AppKit

@main
struct AIAggregatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var usageService = UsageService.shared

    var body: some Scene {
        MenuBarExtra {
            UsagePopoverView()
        } label: {
            Text(menuBarLabel)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarLabel: String {
        let parts = [usageService.chatGptCompact, usageService.claudeCompact].compactMap { $0 }
        return parts.isEmpty ? "A" : parts.joined(separator: "  ")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {}
}
