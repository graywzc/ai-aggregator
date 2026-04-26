import AppKit
import SwiftUI

class WindowManager {
    static let shared = WindowManager()
    
    private var loginWindow: NSWindow?
    
    func showLoginWindow() {
        if loginWindow == nil {
            let contentView = ProviderWebAuthView()
            let hostingController = NSHostingController(rootView: contentView)
            
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
            
            self.loginWindow = window
        }
        
        NSApplication.shared.activate(ignoringOtherApps: true)
        loginWindow?.makeKeyAndOrderFront(nil)
    }
}
