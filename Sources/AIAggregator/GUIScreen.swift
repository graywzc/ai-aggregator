import AppKit

/// The display named by the GUI_SCREEN environment variable, when one by that name is
/// attached: where windows open during development, so a build launched by a coding
/// session stays off the display being worked on. Unset, windows open where they always
/// have (their saved frame, else centered on the main display).
enum GUIScreen {
    static var named: NSScreen? {
        guard let name = ProcessInfo.processInfo.environment["GUI_SCREEN"], !name.isEmpty else { return nil }
        return NSScreen.screens.first { $0.localizedName == name }
    }
}

extension NSWindow {
    /// Centers the window on the GUI_SCREEN display, if one is named and attached. Call after
    /// `center()` and any frame restoration, since both put the window back on the main display.
    func moveToGUIScreen() {
        guard let screen = GUIScreen.named, self.screen != screen else { return }
        let visible = screen.visibleFrame
        var frame = self.frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin = CGPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2)
        setFrame(frame, display: true)
    }
}
