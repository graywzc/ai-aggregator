import Foundation
import SwiftUI

final class ProvidersVisibility: ObservableObject {
    static let shared = ProvidersVisibility()

    @Published var showChatGPT: Bool {
        didSet { UserDefaults.standard.set(showChatGPT, forKey: Self.kChatGPT) }
    }
    @Published var showClaude: Bool {
        didSet { UserDefaults.standard.set(showClaude, forKey: Self.kClaude) }
    }
    @Published var showGemini: Bool {
        didSet { UserDefaults.standard.set(showGemini, forKey: Self.kGemini) }
    }

    @Published var showChatGPTStats: Bool {
        didSet { UserDefaults.standard.set(showChatGPTStats, forKey: Self.kChatGPTStats) }
    }
    @Published var showClaudeStats: Bool {
        didSet { UserDefaults.standard.set(showClaudeStats, forKey: Self.kClaudeStats) }
    }
    @Published var showGeminiStats: Bool {
        didSet { UserDefaults.standard.set(showGeminiStats, forKey: Self.kGeminiStats) }
    }

    private static let kChatGPT      = "show.chatgpt"
    private static let kClaude       = "show.claude"
    private static let kGemini       = "show.gemini"
    private static let kChatGPTStats = "show.chatgpt.stats"
    private static let kClaudeStats  = "show.claude.stats"
    private static let kGeminiStats  = "show.gemini.stats"

    private init() {
        let d = UserDefaults.standard
        showChatGPT      = (d.object(forKey: Self.kChatGPT)      as? Bool) ?? false
        showClaude       = (d.object(forKey: Self.kClaude)       as? Bool) ?? false
        showGemini       = (d.object(forKey: Self.kGemini)       as? Bool) ?? false
        showChatGPTStats = (d.object(forKey: Self.kChatGPTStats) as? Bool) ?? true
        showClaudeStats  = (d.object(forKey: Self.kClaudeStats)  as? Bool) ?? true
        showGeminiStats  = (d.object(forKey: Self.kGeminiStats)  as? Bool) ?? true
    }
}
