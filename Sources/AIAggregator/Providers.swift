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

    private static let kChatGPT = "show.chatgpt"
    private static let kClaude  = "show.claude"
    private static let kGemini  = "show.gemini"

    private init() {
        let d = UserDefaults.standard
        showChatGPT = (d.object(forKey: Self.kChatGPT) as? Bool) ?? true
        showClaude  = (d.object(forKey: Self.kClaude)  as? Bool) ?? true
        showGemini  = (d.object(forKey: Self.kGemini)  as? Bool) ?? true
    }
}
