import SwiftUI

struct UsagePopoverView: View {
    @StateObject private var usageService = UsageService.shared
    @StateObject private var visibility = ProvidersVisibility.shared

    private var anyChatsEnabled: Bool {
        (usageService.chatGptError == nil && !usageService.chatGptWindows.isEmpty && visibility.showChatGPT)
            || (usageService.claudeError == nil && !usageService.claudeWindows.isEmpty && visibility.showClaude)
            || (usageService.geminiError == nil && !usageService.geminiWindows.isEmpty && visibility.showGemini)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ProviderSection(
                name: "ChatGPT",
                windows: usageService.chatGptWindows,
                error: usageService.chatGptError,
                isChatOn: $visibility.showChatGPT,
                isStatsOn: $visibility.showChatGPTStats,
                onLogout: { usageService.logoutChatGPT() },
                onLogin: { WindowManager.shared.showAuthWindow(for: .chatGPT) }
            )

            ProviderSection(
                name: "Claude",
                windows: usageService.claudeWindows,
                error: usageService.claudeError,
                isChatOn: $visibility.showClaude,
                isStatsOn: $visibility.showClaudeStats,
                onLogout: { usageService.logoutClaude() },
                onLogin: { WindowManager.shared.showAuthWindow(for: .claude) }
            )

            ProviderSection(
                name: "Gemini",
                windows: usageService.geminiWindows,
                error: usageService.geminiError,
                isChatOn: $visibility.showGemini,
                isStatsOn: $visibility.showGeminiStats,
                onLogout: { usageService.logoutGemini() },
                onLogin: { WindowManager.shared.showGeminiAuthWindow() }
            )

            Divider()

            HStack {
                if anyChatsEnabled {
                    Button("Aggregated Chats") {
                        WindowManager.shared.showLoginWindow()
                    }
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
    @Binding var isChatOn: Bool
    @Binding var isStatsOn: Bool
    var onLogout: () -> Void
    var onLogin: () -> Void

    private var isLoggedIn: Bool {
        error == nil && !windows.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(name).font(.subheadline).bold()
                Spacer()

                if isLoggedIn {
                    Button(action: onLogout) {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Logout of \(name)")

                    Text("Chat").font(.caption2).foregroundColor(.secondary)
                    Toggle("", isOn: $isChatOn)
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden()

                    Text("Stats").font(.caption2).foregroundColor(.secondary)
                    Toggle("", isOn: $isStatsOn)
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                } else if error != nil {
                    Button("Login") { onLogin() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            if isLoggedIn && isStatsOn {
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
