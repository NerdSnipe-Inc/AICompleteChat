import SwiftUI
import DesignFoundation
import DesignFoundationPro
import AIChatCore
import AIChatUI
import AIChatMLX
import AiPersona
import AiVoiceKit
import AppKit

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
    @State private var chatRecords: [ChatRecord] = []
    @State private var activeChatID: UUID?
    @State private var showMemoryBrowser = false
    @State private var voiceErrorMessage: String?
    /// Non-voice failures the user must see (model unavailable when sending, export failed).
    @State private var appErrorMessage: String?

    init(appEnvironment: AppEnvironment) {
        self.appEnvironment = appEnvironment
        self._voiceEngine = ObservedObject(wrappedValue: appEnvironment.voiceEngine)
        self._session = ObservedObject(wrappedValue: appEnvironment.session)
    }

    var body: some View {
        DFAIChatRootView(
            conversations: appEnvironment.modelLoadState == .ready ? allConversations : [],
            activeConversationID: activeConversationIDBinding,
            model: currentModel,
            onSend: { text in
                if case .modelUnavailable(let message) = appEnvironment.coordinator.send(text) {
                    appErrorMessage = message
                }
            },
            onNewChat: { startNewChat() },
            onDeleteConversation: { id in deleteChat(id) },
            currentUserName: appEnvironment.personaStore.userName.isEmpty ? "You" : appEnvironment.personaStore.userName,
            currentUserEmail: "On-device",
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
        .task {
            await appEnvironment.loadModel()
            bootstrapChatHistory()
        }
        .onChange(of: session.isGenerating) { wasGenerating, isGenerating in
            if wasGenerating && !isGenerating { persistActiveChat() }
        }
        .sheet(isPresented: $showMemoryBrowser) {
            MemoryBrowserView(memoryStore: appEnvironment.memoryStore)
        }
        .sheet(isPresented: $showSettings) {
            DFAIChatSettingsSheet(configuration: .init(
                model: currentModel,
                // AICompleteChat is a fully local, on-device app with no user account and no
                // subscription — DFAIChatSettingsSheet no longer carries Account/Notifications/
                // Manage-Subscription fields, so there's nothing to fake here.
                systemPrompt: "",
                temperature: 0.8,
                maxTokens: 2048,
                memorySnapshot: currentMemorySnapshot,
                voiceHotkeysContent: AnyView(VoiceHotkeysSettingsContent(voiceEngine: appEnvironment.voiceEngine)),
                personaContent: AnyView(PersonaSettingsContent(
                    personaStore: appEnvironment.personaStore,
                    onUserNameSaved: { newName in appEnvironment.rememberUserName(newName) }
                )),
                onReloadModel: { Task { await appEnvironment.loadModel() } },
                onSystemPromptChange: { _ in /* not in Task 13's scope — no system-prompt persistence exists yet */ },
                onTemperatureChange: { _ in /* not in Task 13's scope — no temperature persistence exists yet */ },
                onMaxTokensChange: { _ in /* not in Task 13's scope — no max-tokens persistence exists yet */ },
                onClearMemory: { appEnvironment.memoryStore.deleteAll() },
                onExportMemory: {
                    let export = GraphVisualizationExport.build(
                        fromEntities: appEnvironment.memoryStore.allEntities(),
                        activeFacts: appEnvironment.memoryStore.activeFacts()
                    )
                    let data: Data
                    do { data = try JSONEncoder().encode(export) } catch {
                        appErrorMessage = "Could not export memory: encoding failed (\(error.localizedDescription))."
                        return
                    }
                    let panel = NSSavePanel()
                    panel.allowedContentTypes = [.json]
                    panel.nameFieldStringValue = "AICompleteChat-Memory.json"
                    if panel.runModal() == .OK, let url = panel.url {
                        do { try data.write(to: url) } catch {
                            appErrorMessage = "Could not save the memory export to \(url.lastPathComponent): \(error.localizedDescription)"
                        }
                    }
                },
                onBrowseMemory: { showMemoryBrowser = true },
                onDismiss: { showSettings = false }
            ))
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { appErrorMessage != nil },
            set: { if !$0 { appErrorMessage = nil } }
        )) {
            Button("OK") { appErrorMessage = nil }
        } message: {
            Text(appErrorMessage ?? "")
        }
        .alert("Dictation Unavailable", isPresented: Binding(
            get: { voiceErrorMessage != nil },
            set: { if !$0 { voiceErrorMessage = nil } }
        )) {
            Button("OK") { voiceErrorMessage = nil }
        } message: {
            Text(voiceErrorMessage ?? "")
        }
    }

    /// Every persisted chat as `AIChatConversation` — the active one is built live from
    /// `session.entries` (AIChatUI's streaming display model) so it updates in real time as the
    /// model streams; every other chat is built from its last-saved `storedMessages` snapshot.
    /// Reasoning/tool-call/activity/knowledge-retrieval entries are dropped for v1 — this app
    /// doesn't use tool calling, and surfacing reasoning traces in the UI isn't part of scope.
    private var allConversations: [AIChatConversation] {
        chatRecords.map { chat in
            if chat.id == activeChatID {
                return AIChatConversation(
                    id: chat.id,
                    title: chat.title,
                    messages: liveMessages,
                    model: currentModel,
                    updatedAt: chat.updatedAt
                )
            }
            let messages = chat.storedMessages.map { msg in
                AIChatMessage(role: msg.role == "user" ? .user : .assistant, content: msg.content)
            }
            return AIChatConversation(id: chat.id, title: chat.title, messages: messages, model: currentModel, updatedAt: chat.updatedAt)
        }
    }

    private var liveMessages: [AIChatMessage] {
        session.entries.compactMap { entry in
            switch entry {
            case .userMessage(let e):
                AIChatMessage(role: .user, content: e.text)
            case .aiMessage(let e):
                AIChatMessage(role: .assistant, content: e.text, isStreaming: e.isStreaming)
            case .reasoning, .toolCall, .activity, .knowledgeRetrieval:
                nil
            }
        }
    }

    private var activeConversationIDBinding: Binding<AIChatConversation.ID?> {
        Binding(get: { activeChatID }, set: { selectChat($0) })
    }

    /// Loads every persisted chat at launch, creating a first chat if none exist yet, and selects
    /// the most recently updated one — the fix for "the app always opens to a new chat window and
    /// never shows previous chats" (there was previously zero persistence at all).
    private func bootstrapChatHistory() {
        var chats = appEnvironment.chatHistory.allChats()
        if chats.isEmpty {
            chats = [appEnvironment.chatHistory.createChat()]
        }
        chatRecords = chats
        activeChatID = chats.first?.id
        if let firstChat = chats.first {
            loadChatIntoSession(firstChat)
        }
    }

    private func startNewChat() {
        persistActiveChat()
        let chat = appEnvironment.chatHistory.createChat()
        chatRecords.insert(chat, at: 0)
        session.clearHistory()
        activeChatID = chat.id
    }

    private func selectChat(_ id: UUID?) {
        guard let id, id != activeChatID, let chat = chatRecords.first(where: { $0.id == id }) else { return }
        persistActiveChat()
        loadChatIntoSession(chat)
        activeChatID = id
    }

    /// Deletes a chat from both the on-disk store and the in-memory sidebar list. Deleting the
    /// currently active chat needs its own handling — the live session can't be left pointing at
    /// a chat that no longer exists, so this selects whatever remains (creating a fresh chat if
    /// the list is now empty), the same fallback `bootstrapChatHistory()` uses at launch.
    private func deleteChat(_ id: UUID) {
        appEnvironment.chatHistory.delete(id: id)
        chatRecords.removeAll { $0.id == id }

        guard id == activeChatID else { return }

        if let next = chatRecords.first {
            loadChatIntoSession(next)
            activeChatID = next.id
        } else {
            let chat = appEnvironment.chatHistory.createChat()
            chatRecords = [chat]
            session.clearHistory()
            activeChatID = chat.id
        }
    }

    private func loadChatIntoSession(_ chat: ChatRecord) {
        let entries: [ChatSession.Entry] = chat.storedMessages.map { msg in
            msg.role == "user"
                ? .userMessage(.init(id: UUID(), text: msg.content))
                : .aiMessage(.init(id: UUID(), text: msg.content, isStreaming: false))
        }
        let history: [ChatMessage] = chat.storedMessages.map {
            ChatMessage(role: $0.role == "user" ? .user : .assistant, content: [.text($0.content)])
        }
        session.loadSnapshot(entries: entries, history: history)
    }

    /// Saves the currently active chat's live messages to disk — called after each turn completes
    /// and before switching away from a chat, so nothing typed is ever lost between launches.
    private func persistActiveChat() {
        guard let activeChatID else { return }
        let stored = liveMessages.map { StoredMessage(role: $0.role == .user ? "user" : "assistant", content: $0.content) }
        guard appEnvironment.chatHistory.save(id: activeChatID, messages: stored) else { return }
        if let index = chatRecords.firstIndex(where: { $0.id == activeChatID }) {
            chatRecords[index].updatedAt = Date()
            let record = chatRecords.remove(at: index)
            chatRecords.insert(record, at: 0)
        }
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
            do {
                try await voiceEngine.startDictation()
            } catch {
                // `voiceEngine.state` already reflects the failure (`.error(...)`, mapped to
                // `.idle` for the mic icon) — this alert is what actually tells the user WHY
                // nothing happened, instead of a silent no-op.
                voiceErrorMessage = error.localizedDescription
            }
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
