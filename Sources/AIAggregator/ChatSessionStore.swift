import Foundation
import SwiftUI

struct ChatSession: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var chatGPTURL: String?
    var claudeURL: String?
    var geminiURL: String?
}

final class ChatSessionStore: ObservableObject {
    static let shared = ChatSessionStore()

    @Published var sessions: [ChatSession] = []
    @Published var activeSessionID: UUID?

    private static let kSessions      = "chat.sessions"
    private static let kActiveSession = "chat.active.session"

    private let defaults: UserDefaults

    /// Production singleton — uses UserDefaults.standard.
    private convenience init() { self.init(defaults: .standard) }

    /// Designated initialiser; pass a custom UserDefaults suite for testing.
    init(defaults: UserDefaults) {
        self.defaults = defaults
        load()
    }

    func saveNewSession(name: String, chatGPTURL: URL?, claudeURL: URL?, geminiURL: URL?) {
        let session = ChatSession(
            name: name,
            chatGPTURL: chatGPTURL?.absoluteString,
            claudeURL:  claudeURL?.absoluteString,
            geminiURL:  geminiURL?.absoluteString
        )
        sessions.insert(session, at: 0)
        activeSessionID = session.id
        persist()
    }

    func updateActiveSessionURLs(chatGPTURL: URL?, claudeURL: URL?, geminiURL: URL?) {
        guard let id = activeSessionID,
              let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].chatGPTURL = chatGPTURL?.absoluteString
        sessions[idx].claudeURL  = claudeURL?.absoluteString
        sessions[idx].geminiURL  = geminiURL?.absoluteString
        persist()
    }

    func delete(id: UUID) {
        sessions.removeAll { $0.id == id }
        if activeSessionID == id { activeSessionID = nil }
        persist()
    }

    func setActive(id: UUID?) {
        activeSessionID = id
        defaults.set(id?.uuidString, forKey: Self.kActiveSession)
    }

    private func load() {
        if let data    = defaults.data(forKey: Self.kSessions),
           let decoded = try? JSONDecoder().decode([ChatSession].self, from: data) {
            sessions = decoded
        }
        if let str = defaults.string(forKey: Self.kActiveSession),
           let id  = UUID(uuidString: str),
           sessions.contains(where: { $0.id == id }) {
            activeSessionID = id
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(sessions) {
            defaults.set(data, forKey: Self.kSessions)
        }
        defaults.set(activeSessionID?.uuidString, forKey: Self.kActiveSession)
    }
}
