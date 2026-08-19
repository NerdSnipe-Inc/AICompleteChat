import SwiftUI
import DesignFoundation
import DesignFoundationPro
import AIChatCore
import AIChatUI
import AIChatMLX
import AiPersona
import AiVoiceKit

// NOTE (Task 12 judgment call): the brief's Step 2b `NoopChatProvider` placeholder existed to
// satisfy ContentView's @ObservedObject property wrapper in a placeholder-then-swap init() — see
// ContentView's doc comment below for why that pattern doesn't compile. Since init(appEnvironment:)
// seeds `_session` directly from `appEnvironment.session` with no placeholder step, there's no
// longer a use for a no-op ChatProvider here, so it's omitted rather than left as dead code.

struct ContentView: View {
    // Judgment call (Task 12): the brief's original approach — reading `@Environment` in a
    // placeholder `init()` then reassigning `@ObservedObject` properties from a `.task` closure —
    // does not compile. `ObservedObject.wrappedValue` has a mutating setter, and `body` (and the
    // closures it hands to `.task`) run in a non-mutating context, so `self` is immutable there
    // (verified: "cannot assign to property: 'self' is immutable" at the reassignment site).
    // Fix: accept `AppEnvironment` directly as an init parameter — SwiftUI's "no @Environment in
    // init" restriction only applies to the *property-wrapper* form; a plain parameter passed in
    // from `AICompleteChatApp` (which already holds `appEnvironment` as `@State`) sidesteps it
    // entirely, and lets `_voiceEngine`/`_session` be seeded with the real shared instances up
    // front — no placeholder-then-swap dance needed.
    let appEnvironment: AppEnvironment
    @ObservedObject private var voiceEngine: VoiceEngineMacOS
    @ObservedObject private var session: ChatSession
    @State private var showSettings = false
    @State private var isInspectorVisible = false
    // Stable across re-renders (State's initialValue is only used once, at first materialization)
    // — DFAIChatRootView keys its sidebar selection off this id, so it must not change on every
    // redraw the way a plain `let liveConversationID = UUID()` would.
    @State private var liveConversationID = UUID()

    init(appEnvironment: AppEnvironment) {
        self.appEnvironment = appEnvironment
        self._voiceEngine = ObservedObject(wrappedValue: appEnvironment.voiceEngine)
        self._session = ObservedObject(wrappedValue: appEnvironment.session)
    }

    var body: some View {
        DFAIChatRootView(
            conversations: appEnvironment.modelLoadState == .ready ? [liveConversation] : [],
            model: currentModel,
            onSend: { text in appEnvironment.coordinator.send(text) },
            voiceState: mappedVoiceState,
            voiceTranscript: voiceEngine.transcript,
            onMicTapped: { Task { await toggleDictation() } },
            memorySnapshot: currentMemorySnapshot,
            isInspectorVisible: $isInspectorVisible,
            micPermissionGranted: appEnvironment.micPermissionGranted,
            accessibilityPermissionGranted: appEnvironment.accessibilityPermissionGranted,
            onOpenSystemSettings: { appEnvironment.openSystemSettingsForPermissions() },
            onSettings: { showSettings = true },
            isStreaming: session.isGenerating
        )
        .task { await appEnvironment.loadModel() }
        .sheet(isPresented: $showSettings) {
            DFAIChatSettingsSheet(configuration: .init(
                model: currentModel,
                // Judgment call (Task 12, still true post-Task-13): DFAIChatSettingsSheet.
                // Configuration grew several model-tuning / account / notification fields since
                // this task's brief was written. System-prompt/temperature/max-tokens persistence
                // isn't in Task 13's scope (only reload/clear/export are) — those three remain
                // seeded with fixed values and no-op callbacks here.
                systemPrompt: "",
                temperature: 0.8,
                maxTokens: 2048,
                conversationCount: 1,
                memorySnapshot: currentMemorySnapshot,
                accountConfig: DFAccountBlock.Configuration(
                    avatarInitials: "NS",
                    name: "NerdSnipe",
                    email: "nerdsnipe@example.com",
                    planName: "Local",
                    planBadge: "ON-DEVICE",
                    editTitle: "Edit Profile",
                    manageTitle: "Manage Plan"
                ),
                notificationConfig: DFNotificationPreferencesBlock.Configuration(
                    title: "Notifications",
                    preferences: []
                ),
                voiceHotkeysContent: AnyView(VoiceHotkeysSettingsContent(voiceEngine: appEnvironment.voiceEngine)),
                onReloadModel: { Task { await appEnvironment.loadModel() } },
                onSystemPromptChange: { _ in /* not in Task 13's scope — no system-prompt persistence exists yet */ },
                onTemperatureChange: { _ in /* not in Task 13's scope — no temperature persistence exists yet */ },
                onMaxTokensChange: { _ in /* not in Task 13's scope — no max-tokens persistence exists yet */ },
                onClearHistory: { /* not in Task 13's scope — memory clear/export only, not chat history */ },
                onExportHistory: { /* not in Task 13's scope — memory clear/export only, not chat history */ },
                onClearMemory: { appEnvironment.memoryStore.deleteAll() },
                onExportMemory: {
                    // Task scope ends at producing the export payload — wiring it to a save panel
                    // is a UI detail for whoever picks this up next (NSSavePanel +
                    // JSONEncoder(export) is the straightforward path, matching how the rest of
                    // this app writes files).
                    let export = GraphVisualizationExport.build(
                        fromEntities: appEnvironment.memoryStore.allEntities(),
                        activeFacts: appEnvironment.memoryStore.activeFacts()
                    )
                    _ = export
                },
                onManageSubscription: { /* No subscription model yet — not in scope */ },
                onDismiss: { showSettings = false }
            ))
        }
    }

    /// Bridges `ChatSession.entries` (AIChatUI's streaming display model) into
    /// `AIChatConversation`/`AIChatMessage` (DesignFoundationPro's value types, what
    /// `DFAIChatThreadScreen` actually renders). Reasoning/tool-call/activity/knowledge-retrieval
    /// entries are dropped for v1 — this app doesn't use tool calling, and surfacing reasoning
    /// traces in the UI isn't part of this plan's scope.
    private var liveConversation: AIChatConversation {
        let messages: [AIChatMessage] = session.entries.compactMap { entry in
            switch entry {
            case .userMessage(let e):
                AIChatMessage(role: .user, content: e.text)
            case .aiMessage(let e):
                AIChatMessage(role: .assistant, content: e.text, isStreaming: e.isStreaming)
            case .reasoning, .toolCall, .activity, .knowledgeRetrieval:
                nil
            }
        }
        return AIChatConversation(
            id: liveConversationID,
            title: "Chat",
            messages: messages,
            model: currentModel,
            updatedAt: Date()
        )
    }

    private var currentModel: AIChatOnDeviceModel {
        AIChatOnDeviceModel(
            id: MLXProvider.recommendedModelId(),
            displayName: "Gemma 4 e4b",
            ramTier: "<16GB",
            loadState: appEnvironment.modelLoadState
        )
    }

    private var mappedVoiceState: AIChatVoiceState {
        switch voiceEngine.state {
        case .idle, .error: .idle
        case .recording: .recording
        case .processing: .processing
        }
    }

    private func toggleDictation() async {
        if case .recording = voiceEngine.state {
            _ = await voiceEngine.stopDictation()
        } else {
            try? await voiceEngine.startDictation()
        }
    }

    /// Reads `appEnvironment.memoryUpdateTick` so SwiftUI's Observation framework registers a
    /// dependency on it — `AppEnvironment` is `@Observable`, but only properties actually *read*
    /// during body evaluation trigger a re-render when they change. Without this read, bumping
    /// `memoryUpdateTick` in `PersonaChatCoordinator.onMemoryUpdated` (Task 6) would have no
    /// visible effect and the Memory Inspector panel would never refresh.
    private var currentMemorySnapshot: MemorySnapshot {
        _ = appEnvironment.memoryUpdateTick
        return MemorySnapshotProvider.snapshot(from: appEnvironment.memoryStore)
    }
}
