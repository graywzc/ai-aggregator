import Testing
import Foundation
@testable import AIAggregator

// Each test gets an isolated UserDefaults suite so tests don't bleed into each other.
private func makeStore() -> (ChatSessionStore, UserDefaults) {
    let suiteName = "com.graywzc.AIAggregator.tests.\(UUID().uuidString)"
    let defaults  = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (ChatSessionStore(defaults: defaults), defaults)
}

@Suite("ChatSession Codable")
struct ChatSessionCodableTests {

    @Test func roundTrip() throws {
        let original = ChatSession(
            name: "Test",
            chatGPTURL: "https://chatgpt.com/c/abc",
            claudeURL:  "https://claude.ai/chat/xyz",
            geminiURL:  nil
        )
        let data    = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatSession.self, from: data)

        #expect(decoded.id         == original.id)
        #expect(decoded.name       == original.name)
        #expect(decoded.chatGPTURL == original.chatGPTURL)
        #expect(decoded.claudeURL  == original.claudeURL)
        #expect(decoded.geminiURL  == nil)
    }
}

@Suite("ChatSessionStore — Save")
struct ChatSessionStoreSaveTests {

    @Test func newestSessionAppearsFirst() {
        let (store, _) = makeStore()
        store.saveNewSession(name: "Alpha", chatGPTURL: URL(string: "https://chatgpt.com/c/1"), claudeURL: nil, geminiURL: nil)
        store.saveNewSession(name: "Beta",  chatGPTURL: URL(string: "https://chatgpt.com/c/2"), claudeURL: nil, geminiURL: nil)

        #expect(store.sessions.count == 2)
        #expect(store.sessions[0].name == "Beta")
        #expect(store.sessions[1].name == "Alpha")
    }

    @Test func saveSetsActiveID() {
        let (store, _) = makeStore()
        store.saveNewSession(name: "A", chatGPTURL: nil, claudeURL: nil, geminiURL: nil)
        let idA = store.activeSessionID
        store.saveNewSession(name: "B", chatGPTURL: nil, claudeURL: nil, geminiURL: nil)
        let idB = store.activeSessionID

        #expect(idA != nil)
        #expect(idB != nil)
        #expect(idA != idB)
        #expect(store.sessions.first?.id == idB)
    }

    @Test func saveStoresURLs() {
        let (store, _) = makeStore()
        let chatGPT = URL(string: "https://chatgpt.com/c/abc")!
        let claude  = URL(string: "https://claude.ai/chat/xyz")!
        store.saveNewSession(name: "Nav", chatGPTURL: chatGPT, claudeURL: claude, geminiURL: nil)

        let saved = store.sessions.first!
        #expect(saved.chatGPTURL == chatGPT.absoluteString)
        #expect(saved.claudeURL  == claude.absoluteString)
        #expect(saved.geminiURL  == nil)
    }
}

@Suite("ChatSessionStore — Update")
struct ChatSessionStoreUpdateTests {

    @Test func updateActiveSessionURLs() {
        let (store, _) = makeStore()
        store.saveNewSession(name: "Upd", chatGPTURL: nil, claudeURL: nil, geminiURL: nil)
        let newURL = URL(string: "https://chatgpt.com/c/updated")!
        store.updateActiveSessionURLs(chatGPTURL: newURL, claudeURL: nil, geminiURL: nil)

        #expect(store.sessions.first?.chatGPTURL == newURL.absoluteString)
    }

    @Test func updateIsNoopWithNoActiveSession() {
        let (store, _) = makeStore()
        store.saveNewSession(name: "X", chatGPTURL: nil, claudeURL: nil, geminiURL: nil)
        store.setActive(id: nil)
        store.updateActiveSessionURLs(chatGPTURL: URL(string: "https://chatgpt.com/c/ignored"), claudeURL: nil, geminiURL: nil)

        #expect(store.sessions.first?.chatGPTURL == nil)
    }
}

@Suite("ChatSessionStore — Delete")
struct ChatSessionStoreDeleteTests {

    @Test func deleteRemovesSession() {
        let (store, _) = makeStore()
        store.saveNewSession(name: "Del", chatGPTURL: nil, claudeURL: nil, geminiURL: nil)
        let id = store.sessions.first!.id
        store.delete(id: id)

        #expect(store.sessions.isEmpty)
    }

    @Test func deleteActiveSessionClearsActiveID() {
        let (store, _) = makeStore()
        store.saveNewSession(name: "Active", chatGPTURL: nil, claudeURL: nil, geminiURL: nil)
        let id = store.activeSessionID!
        store.delete(id: id)

        #expect(store.activeSessionID == nil)
    }

    @Test func deleteNonActiveSessionPreservesActiveID() {
        let (store, _) = makeStore()
        store.saveNewSession(name: "Keep",   chatGPTURL: nil, claudeURL: nil, geminiURL: nil)
        let activeID = store.activeSessionID!
        store.saveNewSession(name: "Remove", chatGPTURL: nil, claudeURL: nil, geminiURL: nil)
        let removeID = store.activeSessionID!

        store.setActive(id: activeID)
        store.delete(id: removeID)

        #expect(store.activeSessionID == activeID)
        #expect(store.sessions.count == 1)
    }
}

@Suite("ChatSessionStore — SetActive")
struct ChatSessionStoreSetActiveTests {

    @Test func setActiveUpdatesID() {
        let (store, _) = makeStore()
        store.saveNewSession(name: "S1", chatGPTURL: nil, claudeURL: nil, geminiURL: nil)
        store.saveNewSession(name: "S2", chatGPTURL: nil, claudeURL: nil, geminiURL: nil)
        let s1id = store.sessions[1].id

        store.setActive(id: s1id)
        #expect(store.activeSessionID == s1id)
    }

    @Test func setActiveNilClearsID() {
        let (store, _) = makeStore()
        store.saveNewSession(name: "S", chatGPTURL: nil, claudeURL: nil, geminiURL: nil)
        store.setActive(id: nil)
        #expect(store.activeSessionID == nil)
    }
}

@Suite("ChatSessionStore — Persistence")
struct ChatSessionStorePersistenceTests {

    @Test func sessionsRestoredAcrossInstances() {
        let suiteName = "com.graywzc.AIAggregator.tests.\(UUID().uuidString)"
        let defaults  = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store1 = ChatSessionStore(defaults: defaults)
        store1.saveNewSession(name: "Persisted",
                              chatGPTURL: URL(string: "https://chatgpt.com/c/persist"),
                              claudeURL: nil, geminiURL: nil)
        let savedID = store1.activeSessionID

        let store2 = ChatSessionStore(defaults: defaults)
        #expect(store2.sessions.count == 1)
        #expect(store2.sessions.first?.name == "Persisted")
        #expect(store2.sessions.first?.chatGPTURL == "https://chatgpt.com/c/persist")
        #expect(store2.activeSessionID == savedID)
    }

    @Test func activeIDNotRestoredAfterSessionDeleted() {
        let suiteName = "com.graywzc.AIAggregator.tests.\(UUID().uuidString)"
        let defaults  = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store1 = ChatSessionStore(defaults: defaults)
        store1.saveNewSession(name: "Gone", chatGPTURL: nil, claudeURL: nil, geminiURL: nil)
        let id = store1.activeSessionID!
        store1.delete(id: id)

        let store2 = ChatSessionStore(defaults: defaults)
        #expect(store2.activeSessionID == nil)
    }
}
