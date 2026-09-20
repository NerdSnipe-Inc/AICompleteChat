import Foundation
import Observation
import AIChatCore
import AIChatUI
import AIChatMLX
import AiPersona
import AiVoiceKit
import DesignFoundationPro
import AVFoundation
import ApplicationServices
import AppKit
import os

@MainActor
@Observable
final class AppEnvironment {
    let mlxProvider: MLXProvider
    let session: ChatSession
    let memoryStore: MemoryGraphStore
    let retrieval: RetrievalService
    let personaStore: PersonaStore
    let coordinator: PersonaChatCoordinator
    let voiceEngine: VoiceEngineMacOS
    let chatHistory: ChatHistoryStore

    /// Real load-state for the on-device MLX model, replacing Task 12's hardcoded `.ready`
    /// placeholder in ContentView's `currentModel`. Starts at `.notLoaded` until `loadModel()` is
    /// called (from ContentView's `.task` modifier, so it kicks off automatically at launch).
    var modelLoadState: AIChatModelLoadState = .notLoaded

    /// Bumped by `coordinator.onMemoryUpdated` after each background ingestion completes.
    /// `AppEnvironment` is `@Observable`, so any view reading this property re-renders when it
    /// changes — this is what makes the Memory Inspector panel (Task 8/12) actually pick up new
    /// facts, since `MemoryGraphStore` itself has no Observable/Combine surface to watch directly.
    private(set) var memoryUpdateTick = 0

    private static let logger = Logger(subsystem: "cc.nerdsnipe.AICompleteChat", category: "AppEnvironment")

    init() {
        let mlxProvider = MLXProvider() // defaults to MLXProvider.recommendedModelId() = gemma-4-e4b-it-4bit
        let session = ChatSession(provider: mlxProvider, model: MLXProvider.recommendedModelId())
        let memoryStore = MemoryGraphStore.shared
        let retrieval = RetrievalService(store: memoryStore)
        let personaStore = PersonaStore.shared
        // Extraction gets its OWN provider instance: deterministic (temperature 0) and length-capped,
        // instead of sharing the chat provider's creative sampling (0.6) and unbounded generation.
        // Same model id + residency slot, so it reuses the already-resident weights (no second load);
        // requests queue behind chat on MLX's single ModelContainer, so a background extraction can
        // delay — but never corrupt or deadlock — a chat turn.
        let extractionProvider = MLXProvider(modelId: MLXProvider.recommendedModelId(), maxTokens: 768, temperature: 0)
        let memoryProvider = LocalMemoryProvider(mlxProvider: extractionProvider, modelId: MLXProvider.recommendedModelId())
        let coordinator = PersonaChatCoordinator(
            session: session, store: memoryStore, retrieval: retrieval,
            memoryProvider: memoryProvider, personaStore: personaStore
        )

        self.mlxProvider = mlxProvider
        self.session = session
        self.memoryStore = memoryStore
        self.retrieval = retrieval
        self.personaStore = personaStore
        self.coordinator = coordinator
        self.chatHistory = ChatHistoryStore()

        // VoiceEngineMacOS's closures must be assigned after `coordinator` exists (it needs
        // `self` to be fully initialized first) — this is the documented pattern in
        // VoiceEngineMacOS's own doc comments ("Updated by the host app after the view
        // hierarchy is ready").
        let voiceEngine = VoiceEngineMacOS(onCommandReceived: { _ in })
        self.voiceEngine = voiceEngine
        voiceEngine.onCommandReceived = { [coordinator] text in
            coordinator.send(text)
        }
        coordinator.readiness = { [weak self] in
            guard let self else { return .notLoaded }
            return switch self.modelLoadState {
            case .ready: .ready
            case .downloading(let progress): .loading(progress: progress)
            case .error(let reason): .failed(reason)
            case .notLoaded: .notLoaded
            }
        }
        voiceEngine.onEditRequested = { [mlxProvider] selectedText, instruction in
            let options = ChatRequestOptions(
                systemPrompt: "Rewrite the given text according to the instruction. Respond with ONLY the rewritten text, no commentary."
            )
            let prompt = "Instruction: \(instruction)\n\nText:\n\(selectedText)"
            do {
                let result = try await mlxProvider.complete(
                    messages: [ChatMessage(role: .user, content: prompt)],
                    model: MLXProvider.recommendedModelId(),
                    options: options
                )
                guard case .text(let rewritten) = result.message.content.first, !rewritten.isEmpty else {
                    Self.logger.error("voice edit: model returned no text; leaving selection unchanged")
                    return selectedText
                }
                return rewritten
            } catch {
                // Returning the original text is the safe fallback for a text edit, but the failure
                // must be visible — it used to be swallowed by `try?`.
                Self.logger.error("voice edit failed: \(error.localizedDescription, privacy: .public)")
                return selectedText
            }
        }

        // Assigned last, after every stored property above is set — Swift forbids capturing
        // `self` (even weakly) inside `init` until all stored properties are initialized, and
        // `self.voiceEngine` (assigned just above) was the last one.
        coordinator.onMemoryUpdated = { [weak self] in self?.memoryUpdateTick += 1 }
    }

    // MARK: - Permission checks (Task 14)
    //
    // Mirrors Alric's proven, shipped pattern: `AVCaptureDevice.authorizationStatus(for:)` for
    // mic (see alric/Features/Voice/Settings/VoiceEngineSettingsView.swift) and
    // `AXIsProcessTrusted()` for Accessibility (see
    // alric/Features/Voice/Settings/VoiceHotkeysSettingsView.swift). These are computed, not
    // cached — they're read fresh by ContentView on each body evaluation, same as Alric's
    // `.onAppear` refresh does for its own settings rows.

    /// Whether microphone access is currently authorized. Feeds `DFAIChatNewScreen`'s mic
    /// permission banner via `DFAIChatRootView`.
    var micPermissionGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Whether this process is trusted for Accessibility (required for global hotkey capture).
    /// Feeds `DFAIChatNewScreen`'s Accessibility permission banner via `DFAIChatRootView`.
    var accessibilityPermissionGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Requests mic access via the system prompt. Only has an effect the first time — once the
    /// user has answered (either way), `AVCaptureDevice.requestAccess` returns immediately with
    /// the prior answer and the user must go to System Settings to change it.
    func requestMicPermission() async {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Opens System Settings to the microphone privacy pane — the same deep link Alric's own
    /// mic permission row uses (`VoiceEngineSettingsView.swift`).
    func openSystemSettingsForPermissions() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Loads the on-device MLX model, tracking real progress in `modelLoadState` so the New
    /// Screen can show genuine download progress instead of Task 12's hardcoded `.ready`.
    /// Called from ContentView's `.task` modifier at launch, and again from Settings'
    /// "Reload Model" action.
    /// Records the human user's own name into the memory graph as a real, durable entity + fact —
    /// so the model actually knows who it's talking to, and the name shows up in the Memory
    /// browser like any other known fact rather than only living in a settings field nobody but
    /// the sidebar footer reads. Called after `PersonaSettingsContent` actually changes
    /// `personaStore.userName` (a no-op save is filtered out before this is invoked).
    func rememberUserName(_ name: String) {
        guard !name.isEmpty else { return }
        let entity = memoryStore.upsertEntity(
            name: name, summary: "The person using this app.", kind: .user,
            embedding: LocalEmbedder.embed(name)
        )
        let factText = "The user's name is \(name)."
        let alreadyKnown = memoryStore.activeFacts().contains {
            $0.subjectID == entity.id && $0.factText.caseInsensitiveCompare(factText) == .orderedSame
        }
        guard !alreadyKnown else { return }
        memoryStore.addFact(
            subjectID: entity.id, objectID: nil, predicate: "is named",
            factText: factText, embedding: LocalEmbedder.embed(factText)
        )
        memoryUpdateTick += 1
    }

    /// Human-readable, cause-specific text for a model load failure.
    nonisolated static func describeLoadFailure(_ error: Error) -> String {
        // AIChatCore's classified errors already carry a cause-specific description AND a next step.
        if let chat = error as? ChatError, let description = chat.errorDescription {
            return [description, chat.recoverySuggestion].compactMap { $0 }.joined(separator: " ")
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "no network connection — the model needs to be downloaded once (\(urlError.localizedDescription))"
            case .timedOut:
                return "the model download timed out — check your connection and retry"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "could not reach the model host (\(urlError.localizedDescription))"
            default:
                return "network error while fetching the model (\(urlError.localizedDescription))"
            }
        }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError {
            return "not enough free disk space to store the model"
        }
        let described = (error as? LocalizedError)?.errorDescription ?? ns.localizedDescription
        // Generic Cocoa fallback text carries no information; append the raw domain/code.
        if described.hasPrefix("The operation couldn") {
            return "\(described) [\(ns.domain) \(ns.code)]"
        }
        return described
    }

    func loadModel() async {
        modelLoadState = .downloading(progress: 0)
        do {
            try await mlxProvider.loadModel { progress in
                Task { @MainActor in
                    self.modelLoadState = .downloading(progress: progress.fractionCompleted)
                }
            }
            modelLoadState = .ready
        } catch {
            // Surface the specific message plus what the user can do about it. Set
            // AICHAT_DEBUG=1 (or `ChatLog.debugMode = true`) for the full error chain in the log.
            let message = error.localizedDescription
            if let hint = (error as? LocalizedError)?.recoverySuggestion {
                modelLoadState = .error("\(message) \(hint)")
            } else {
                modelLoadState = .error(message)
            }
        }
    }
}
