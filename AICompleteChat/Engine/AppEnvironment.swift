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

    /// Real load-state for the on-device MLX model, replacing Task 12's hardcoded `.ready`
    /// placeholder in ContentView's `currentModel`. Starts at `.notLoaded` until `loadModel()` is
    /// called (from ContentView's `.task` modifier, so it kicks off automatically at launch).
    var modelLoadState: AIChatModelLoadState = .notLoaded

    /// Bumped by `coordinator.onMemoryUpdated` after each background ingestion completes.
    /// `AppEnvironment` is `@Observable`, so any view reading this property re-renders when it
    /// changes — this is what makes the Memory Inspector panel (Task 8/12) actually pick up new
    /// facts, since `MemoryGraphStore` itself has no Observable/Combine surface to watch directly.
    private(set) var memoryUpdateTick = 0

    init() {
        let mlxProvider = MLXProvider() // defaults to MLXProvider.recommendedModelId() = gemma-4-e4b-it-4bit
        let session = ChatSession(provider: mlxProvider, model: MLXProvider.recommendedModelId())
        let memoryStore = MemoryGraphStore.shared
        let retrieval = RetrievalService(store: memoryStore)
        let personaStore = PersonaStore.shared
        let memoryProvider = LocalMemoryProvider(mlxProvider: mlxProvider, modelId: MLXProvider.recommendedModelId())
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

        // VoiceEngineMacOS's closures must be assigned after `coordinator` exists (it needs
        // `self` to be fully initialized first) — this is the documented pattern in
        // VoiceEngineMacOS's own doc comments ("Updated by the host app after the view
        // hierarchy is ready").
        let voiceEngine = VoiceEngineMacOS(onCommandReceived: { _ in })
        self.voiceEngine = voiceEngine
        voiceEngine.onCommandReceived = { [coordinator] text in
            coordinator.send(text)
        }
        voiceEngine.onEditRequested = { [mlxProvider] selectedText, instruction in
            let options = ChatRequestOptions(
                systemPrompt: "Rewrite the given text according to the instruction. Respond with ONLY the rewritten text, no commentary."
            )
            let prompt = "Instruction: \(instruction)\n\nText:\n\(selectedText)"
            guard let result = try? await mlxProvider.complete(
                messages: [ChatMessage(role: .user, content: prompt)],
                model: MLXProvider.recommendedModelId(),
                options: options
            ), case .text(let rewritten) = result.message.content.first else {
                return selectedText
            }
            return rewritten
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
            modelLoadState = .error(error.localizedDescription)
        }
    }
}
