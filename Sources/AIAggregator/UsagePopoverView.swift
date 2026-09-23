import SwiftUI

struct UsagePopoverView: View {
    @StateObject private var usageService = UsageService.shared
    @StateObject private var speedStats = SpeedStatsService.shared
    @StateObject private var visibility = ProvidersVisibility.shared

    private var anyChatsEnabled: Bool {
        (usageService.chatGptError == nil && !usageService.chatGptWindows.isEmpty && visibility.showChatGPT)
            || (usageService.claudeError == nil && !usageService.claudeWindows.isEmpty && visibility.showClaude)
            || visibility.showGemini
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

            // Gemini has no usage stats: Google shut down the Code Assist quota API
            // for individual accounts. The chat pane signs in through its own web view.
            ChatOnlySection(name: "Gemini", isChatOn: $visibility.showGemini)

            SpeedSection(stats: speedStats, isOn: $visibility.showClaudeCodeSpeed)

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

private struct ChatOnlySection: View {
    let name: String
    @Binding var isChatOn: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(name).font(.subheadline).bold()
            Spacer()
            Text("Chat").font(.caption2).foregroundColor(.secondary)
            Toggle("", isOn: $isChatOn)
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
    }
}

/// Claude Code request speed, fed by its OpenTelemetry export (see README).
private struct SpeedSection: View {
    @ObservedObject var stats: SpeedStatsService
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Claude Code").font(.subheadline).bold()
                Spacer()
                Text("Speed").font(.caption2).foregroundColor(.secondary)
                Toggle("", isOn: $isOn)
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
            }

            if isOn {
                if let error = stats.listenerError {
                    Text(error).font(.caption2).foregroundColor(.orange)
                } else if let last = stats.latest {
                    SpeedRow(label: "last:", request: last)
                    if let avg = stats.averageGenTokensPerSec {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text("avg:").frame(width: 45, alignment: .leading).foregroundColor(.secondary)
                                Text("\(Int(avg.rounded())) t/s")
                                if let ttft = stats.averageTtftMs {
                                    Text("ttft \(formatSeconds(ttft))").foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                            if let prefill = stats.averagePrefillTokensPerSec {
                                HStack(spacing: 4) {
                                    Text("").frame(width: 45)
                                    Text("prefill \(Int(prefill.rounded())) t/s").foregroundColor(.secondary)
                                    Spacer()
                                }
                            }
                        }
                        .font(.system(size: 12, design: .monospaced))
                    }
                } else {
                    Text("Waiting for telemetry on 127.0.0.1:\(String(SpeedStatsService.port))")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
        }
    }
}

private func formatSeconds(_ ms: Double) -> String { String(format: "%.1fs", ms / 1000) }

private struct SpeedRow: View {
    let label: String
    let request: RequestSpeed

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(label).frame(width: 45, alignment: .leading).foregroundColor(.secondary)
                if let gen = request.genTokensPerSec { Text("\(Int(gen.rounded())) t/s") }
                if let ttft = request.ttftMs {
                    Text("ttft \(formatSeconds(ttft))").foregroundColor(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 4) {
                Text("").frame(width: 45)
                Text("\(request.inputTokens) in / \(request.outputTokens) out")
                if let prefill = request.prefillTokensPerSec {
                    Text("prefill \(Int(prefill.rounded())) t/s")
                }
                Spacer()
            }
            .foregroundColor(.secondary)
        }
        .font(.system(size: 12, design: .monospaced))
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
                } else if let error {
                    if error != "Login Required" && error != "Logged Out" {
                        Text(error)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .help(error)
                    }
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

    private func formatReset(_ date: Date) -> String { formatResetDate(date) }
}
