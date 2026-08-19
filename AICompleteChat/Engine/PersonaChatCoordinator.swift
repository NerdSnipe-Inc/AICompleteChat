import Foundation
import Combine
import AIChatCore
import AIChatUI
import AiPersona

/// The one orchestration type this app adds on top of ChatSession: folds AiPersona memory
/// context into the system prompt before each send, and triggers background fact ingestion
/// after each turn completes. Does not duplicate ChatSession's streaming/entries state — reads
/// and writes through it directly.
@MainActor
final class PersonaChatCoordinator {
    private let session: ChatSession
    private let store: MemoryGraphStore
    private let retrieval: RetrievalService
    private let memoryProvider: MemoryProvider
    private let personaStore: PersonaStore

    private var isGeneratingCancellable: AnyCancellable?
    private var pendingUserText: String?

    /// Fires after background ingestion finishes writing to `store` — `MemoryGraphStore` has no
    /// Combine/Observable surface of its own (verified: its public API is plain synchronous
    /// methods only), so without this callback nothing tells the UI a new fact just landed and
    /// the Memory Inspector panel would only refresh on an unrelated re-render.
    var onMemoryUpdated: (() -> Void)?

    init(
        session: ChatSession,
        store: MemoryGraphStore,
        retrieval: RetrievalService,
        memoryProvider: MemoryProvider,
        personaStore: PersonaStore
    ) {
        self.session = session
        self.store = store
        self.retrieval = retrieval
        self.memoryProvider = memoryProvider
        self.personaStore = personaStore

        // Fires once per generation cycle: true -> false. dropFirst() skips the initial `false`
        // published at subscription time (Combine replays the current value immediately).
        isGeneratingCancellable = session.$isGenerating
            .dropFirst()
            .filter { $0 == false }
            .sink { [weak self] _ in self?.handleTurnCompleted() }
    }

    /// Sends `text`, having first folded in persona identity + retrieved memory context.
    func send(_ text: String) {
        let compilation = retrieval.sessionCompilation()
        let perTurn = retrieval.perTurnMemoryBlock(forQuery: text, excluding: compilation)
        let combined = [compilation, perTurn]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        session.options.systemPrompt = PersonaPromptBuilder.identityPreamble(
            name: personaStore.name, personality: personaStore.personality
        ) + PersonaPromptBuilder.memorySection(combined.isEmpty ? nil : combined)

        pendingUserText = text
        let knowledge = perTurn.map { ChatSession.KnowledgeRetrievalInjection(query: text, body: $0) }
        session.send(text, knowledge: knowledge)
    }

    private func handleTurnCompleted() {
        guard let userText = pendingUserText else { return }
        pendingUserText = nil

        let assistantText = session.entries.reversed().lazy.compactMap { entry -> String? in
            if case .aiMessage(let e) = entry { return e.text }
            return nil
        }.first ?? ""
        guard !assistantText.isEmpty else { return }

        let episode = ChatEpisode(userText: userText, assistantText: assistantText, occurredAt: Date())
        let provider = memoryProvider
        let store = store
        Task {
            _ = await IngestionActor.shared.enqueue(episode, provider: provider, store: store)
            onMemoryUpdated?()
        }
    }
}
