import Foundation
import Testing
import AIChatCore
import AIChatUI
import AiPersona
@testable import AICompleteChat

@MainActor
@Suite("PersonaChatCoordinator")
struct PersonaChatCoordinatorTests {

    @Test("injects sessionCompilation as system prompt identity + memory preamble")
    func injectsMemoryContext() async throws {
        let provider = FakeChatProvider()
        let session = ChatSession(provider: provider, model: "test")
        let store = MemoryGraphStore(inMemory: true)
        let retrieval = RetrievalService(store: store)
        let personaStore = PersonaStore(defaults: UserDefaults(suiteName: "test-\(UUID())")!)
        let coordinator = PersonaChatCoordinator(
            session: session, store: store, retrieval: retrieval,
            memoryProvider: LocalMemoryProviderStub(), personaStore: personaStore
        )

        coordinator.send("Hello")
        // Wait for the fire-and-forget stream to complete.
        try await Task.sleep(nanoseconds: 500_000_000)

        #expect(provider.lastSystemPrompt?.contains(personaStore.name) == true)
        #expect(session.entries.contains { if case .userMessage(let e) = $0 { return e.text == "Hello" } else { return false } })
    }

    @Test("invokes onMemoryUpdated after a turn completes")
    func invokesOnMemoryUpdatedAfterTurn() async throws {
        let provider = FakeChatProvider()
        let session = ChatSession(provider: provider, model: "test")
        let store = MemoryGraphStore(inMemory: true)
        let retrieval = RetrievalService(store: store)
        let personaStore = PersonaStore(defaults: UserDefaults(suiteName: "test-\(UUID())")!)
        let coordinator = PersonaChatCoordinator(
            session: session, store: store, retrieval: retrieval,
            memoryProvider: LocalMemoryProviderStub(), personaStore: personaStore
        )

        var wasCalled = false
        coordinator.onMemoryUpdated = { wasCalled = true }

        coordinator.send("Hello")
        try await Task.sleep(nanoseconds: 500_000_000)

        #expect(wasCalled)
    }
}

/// Never called in this test (no facts exist yet to extract from an empty in-memory store's
/// perspective before the turn completes) but required to satisfy the `MemoryProvider` protocol.
struct LocalMemoryProviderStub: MemoryProvider {
    func extractFacts(fromEpisode text: String) async throws -> [ExtractedFact] { [] }
}
