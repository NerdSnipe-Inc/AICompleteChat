import Foundation
import Combine
import AIChatCore
import AIChatUI
import AiPersona
import os

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

    private let logger = Logger(subsystem: "cc.nerdsnipe.AICompleteChat", category: "PersonaChatCoordinator")

    /// What the host currently knows about the on-device model. The coordinator has no MLX access
    /// of its own; without this a voice command (which bypasses the UI's "model ready" gate) would
    /// silently kick off a multi-GB download/load inside `ChatSession` and hang the turn.
    enum ModelReadiness: Equatable {
        case ready
        case loading(progress: Double?)
        case failed(String)
        case notLoaded
    }

    /// Result of `send`. Only `.sent` starts a turn; every other case leaves the session
    /// untouched. `.modelUnavailable` carries the user-facing sentence for the caller to show
    /// (`ChatSession.ActivityEntry` has no public initializer, so the coordinator cannot add an
    /// inline row itself).
    enum SendOutcome: Equatable {
        case sent
        case ignoredEmpty
        case ignoredBusy
        case modelUnavailable(String)
    }

    /// Supplied by `AppEnvironment` (reads its `modelLoadState`). Defaults to `.ready` so the
    /// coordinator stays usable with a fake provider in tests.
    var readiness: @MainActor () -> ModelReadiness = { .ready }

    /// Fires when an ingested episode produced corrections that need a human (`EnqueueResult
    /// .needsHumanReview`) — previously the result was discarded, so a correction that could not be
    /// applied (or that hit a hand-edited fact) vanished without a trace.
    var onCorrectionsNeedReview: ((EnqueueResult) -> Void)?

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

    /// User-facing sentence for a model that is not ready to answer.
    static func message(for readiness: ModelReadiness) -> String? {
        switch readiness {
        case .ready: nil
        case .loading(let progress):
            if let progress { "The on-device model is still loading (\(Int(progress * 100))%). Try again in a moment." }
            else { "The on-device model is still loading. Try again in a moment." }
        case .failed(let reason):
            "The on-device model failed to load: \(reason)\(reason.hasSuffix(".") ? "" : ".") Use Settings > Reload Model to retry."
        case .notLoaded:
            "The on-device model has not been loaded yet. Open Settings and choose Reload Model."
        }
    }

    /// Sends `text`, having first folded in persona identity + retrieved memory context.
    ///
    /// Refuses (and says why) rather than silently dropping: an empty message, a turn already in
    /// flight (the old code overwrote `pendingUserText` here even though `ChatSession.send` ignored
    /// the message, so the next ingested episode paired the WRONG user text with the answer), or a
    /// model that is not ready.
    @discardableResult
    func send(_ text: String) -> SendOutcome {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .ignoredEmpty }
        guard !session.isGenerating else {
            logger.notice("send ignored: a turn is already in flight")
            return .ignoredBusy
        }
        if let problem = Self.message(for: readiness()) {
            logger.error("send refused, model not ready: \(problem, privacy: .public)")
            return .modelUnavailable(problem)
        }

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
        return .sent
    }

    private func handleTurnCompleted() {
        guard let userText = pendingUserText else { return }
        pendingUserText = nil

        // A failed/cancelled turn may leave a partial answer; learning facts from it (or from a
        // reply that never completed) would pollute memory. Log why instead of dropping silently.
        if let error = session.error {
            logger.error("turn failed, skipping memory ingestion: \(ChatLog.errorChain(error), privacy: .public)")
            return
        }

        let assistantText = session.entries.reversed().lazy.compactMap { entry -> String? in
            if case .aiMessage(let e) = entry { return e.text }
            return nil
        }.first ?? ""
        guard !assistantText.isEmpty else {
            logger.notice("turn produced no assistant text, skipping memory ingestion")
            return
        }

        let episode = ChatEpisode(userText: userText, assistantText: assistantText, occurredAt: Date())
        let provider = memoryProvider
        let store = store
        let knownUserName = personaStore.userName
        Task {
            let result = await IngestionActor.shared.enqueue(episode, provider: provider, store: store, knownUserName: knownUserName)
            if result.needsHumanReview {
                logger.notice("ingestion: \(result.failedCorrections.count) unapplied, \(result.pendingReviewCorrections.count) pending-review correction(s)")
                onCorrectionsNeedReview?(result)
            }
            onMemoryUpdated?()
        }
    }
}
