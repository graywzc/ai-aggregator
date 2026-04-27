import SwiftUI

struct UsagePopoverView: View {
    @StateObject private var usageService = UsageService.shared
    @StateObject private var visibility = ProvidersVisibility.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ProviderSection(name: "ChatGPT",
                            windows: usageService.chatGptWindows,
                            error: usageService.chatGptError,
                            isVisible: $visibility.showChatGPT,
                            onLogout: { usageService.logoutChatGPT() })

            ProviderSection(name: "Claude",
                            windows: usageService.claudeWindows,
                            error: usageService.claudeError,
                            isVisible: $visibility.showClaude,
                            onLogout: { usageService.logoutClaude() })

            ProviderSection(name: "Gemini",
                            windows: usageService.geminiWindows,
                            error: usageService.geminiError,
                            isVisible: $visibility.showGemini,
                            onLogout: { usageService.logoutGemini() })

            Divider()

            HStack {
                Button("Login to Providers") {
                    WindowManager.shared.showLoginWindow()
                }
                
                Spacer()
                
                if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                    Text("v\(version)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding()
        .frame(width: 320)
    }
}

private struct ProviderSection: View {
    let name: String
    let windows: [UsageWindow]
    let error: String?
    @Binding var isVisible: Bool
    var onLogout: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name).font(.subheadline).bold()
                Spacer()
                
                if error != "Logged Out" && (error == nil || !windows.isEmpty) {
                    Button(action: onLogout) {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Logout of \(name)")
                }
                
                Toggle("", isOn: $isVisible)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            if let error = error {
                Text(error).font(.caption).foregroundColor(error == "Logged Out" ? .secondary : .red)
            } else if !windows.isEmpty {
                ForEach(windows) { w in
                    WindowRow(window: w)
                }
            }
        }
    }
}

private struct WindowRow: View {
    let window: UsageWindow

    private var color: Color {
        window.percentRemaining < 20 ? .orange : .primary
    }

    var body: some View {
        HStack(spacing: 4) {
            Text("\(window.label):")
                .frame(width: 45, alignment: .leading)
                .foregroundColor(.secondary)
            Text("\(window.percentRemaining)%")
                .foregroundColor(color)
                .frame(width: 42, alignment: .leading)
            if let reset = window.resetsAt {
                Text("resets \(formatReset(reset))")
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .font(.system(size: 12, design: .monospaced))
    }

    private func formatReset(_ date: Date) -> String {
        let cal = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = cal.isDate(date, inSameDayAs: Date()) ? "HH:mm" : "EEE HH:mm"
        return formatter.string(from: date)
    }
}
