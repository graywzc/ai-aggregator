import AppKit
import SwiftUI

enum AuthProvider {
    case chatGPT, claude

    var name: String {
        switch self {
        case .chatGPT: return "ChatGPT"
        case .claude:  return "Claude"
        }
    }

    var url: URL {
        switch self {
        case .chatGPT: return URL(string: "https://auth.openai.com/log-in-or-create-account")!
        case .claude:  return URL(string: "https://claude.ai/login")!
        }
    }
}

class WindowManager {
    static let shared = WindowManager()

    private var loginWindow: NSWindow?
    private var authWindow: NSWindow?

    func showLoginWindow() {
        if loginWindow == nil {
            let hostingController = NSHostingController(rootView: ProviderWebAuthView())
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1500, height: 700),
                styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "AI Chat"
            window.contentViewController = hostingController
            window.center()
            window.setFrameAutosaveName("ProviderLoginWindow")
            window.isReleasedWhenClosed = false
            window.collectionBehavior.insert(.fullScreenPrimary)
            loginWindow = window
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        loginWindow?.makeKeyAndOrderFront(nil)
    }

    func showGeminiAuthWindow() {
        authWindow?.close()
        authWindow = nil

        let view = GeminiAuthView { [weak self] in
            DispatchQueue.main.async {
                self?.authWindow?.close()
                self?.authWindow = nil
            }
        }
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sign in to Gemini"
        window.contentViewController = hostingController
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 640)
        authWindow = window

        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func showAuthWindow(for provider: AuthProvider) {
        authWindow?.close()
        authWindow = nil

        let view = ProviderAuthView(provider: provider) { [weak self] in
            DispatchQueue.main.async {
                self?.authWindow?.close()
                self?.authWindow = nil
            }
        }
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sign in to \(provider.name)"
        window.contentViewController = hostingController
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 640)
        authWindow = window

        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
