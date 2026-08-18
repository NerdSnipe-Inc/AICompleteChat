# AICompleteChat Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build AICompleteChat — a standalone, production-quality macOS on-device AI chat app with voice input and persistent memory, serving as the flagship full-source example for AiVoiceKit and DesignFoundationPro.

**Architecture:** `ChatSession` (AIChatUI) stays the source of truth for chat/streaming state; `MLXProvider` (AIChatMLX) supplies on-device inference (`gemma-4-e4b-it-4bit`); a single new type, `PersonaChatCoordinator`, wraps `ChatSession.send` to inject AiPersona memory context before a turn and trigger fact ingestion after one; `VoiceEngineMacOS` (AiVoiceKit) is owned at the app root and wired via its two callbacks. DesignFoundationPro's `AIChat` vertical is redesigned (breaking change, major version bump) around a single streaming on-device model instead of static cloud-model comparison.

**Tech Stack:** Swift 6, SwiftUI, macOS 15+, SwiftData (via AiPersona), MLX (via AIChatKitMLX), local SPM package references.

**Spec:** `~/Projects/AICompleteChat/docs/superpowers/specs/2026-08-18-aicompletechat-design.md`

## Global Constraints

- macOS 15+ only, Swift 6, Xcode 16+ (matches DesignFoundation/DesignFoundationPro's stated requirements).
- Zero network calls for inference or memory extraction — on-device only, no API keys (`AIChatOpenAI`/`AIChatAnthropic` are never added as dependencies).
- `PersonaChatCoordinator` is the only new orchestration type — do not duplicate `ChatSession`'s streaming state or `VoiceEngineMacOS`'s recording state anywhere else.
- Breaking changes to DesignFoundationPro's `AIChat` vertical are approved — bump `DesignFoundationPro`'s version to `2.0.0` and add a CHANGELOG entry when that work lands.
- Every screen's non-happy states (loading, empty, error, permission-denied) must be real, designed states per `~/Projects/DesignFoundationPro/docs/QUALITY-GATE.md` — never a placeholder.
- No remote repos are created or pushed for `AICompleteChat` or `AiVoiceKit` as part of this plan — both stay local-only.
- DMG signing/notarization and how the build artifact is referenced from AiVoiceKit are explicitly out of scope for this plan.

---

## Task 1: Xcode project scaffold + local package wiring

**Files:**
- Create: `~/Projects/AICompleteChat/AICompleteChat.xcodeproj` (via Xcode, not hand-authored — see Step 1)
- Create: `~/Projects/AICompleteChat/AICompleteChat/AICompleteChatApp.swift`
- Create: `~/Projects/AICompleteChat/AICompleteChat/ContentView.swift`
- Create: `~/Projects/AICompleteChat/.gitignore`

**Interfaces:**
- Produces: a buildable macOS app target named `AICompleteChat` with all six packages linked as `XCSwiftPackageProductDependency` entries — every later task's `import` statements depend on this.

- [ ] **Step 1: Create the Xcode project**

In Xcode: File → New → Project → macOS → App. Configure:
- Product Name: `AICompleteChat`
- Interface: SwiftUI
- Language: Swift
- Save to: `~/Projects/AICompleteChat`

In the target's Build Settings, set macOS Deployment Target to `15.0`. In Signing & Capabilities, use your existing Apple Development signing identity (same as used for `alric.xcodeproj`) — do not configure a Developer ID/notarization identity yet, that's out of scope here.

- [ ] **Step 2: Add local package dependencies**

File → Add Package Dependencies → Add Local… and add each of these six paths (this mirrors exactly how `alric.xcodeproj` consumes `AiVoiceKit` — verified working earlier this session):

```
~/Projects/DesignFoundation
~/Projects/DesignFoundationPro
~/xCodeProjects/NerdSnipe-Inc-Packages/AIChatKit
~/xCodeProjects/NerdSnipe-Inc-Packages/AIChatKitMLX
~/xCodeProjects/NerdSnipe-Inc-Packages/AiPersona
~/xCodeProjects/NerdSnipe-Inc-Packages/AiVoiceKit
```

For the `AICompleteChat` target, add these products under "Frameworks, Libraries, and Embedded Content":
`DesignFoundation`, `DesignFoundationPro`, `AIChatCore`, `AIChatUI`, `AIChatMLX`, `AiPersona`, `AiVoiceKit`.

Do **not** add `AIChatOpenAI` or `AIChatAnthropic` (Global Constraint: zero network calls for inference).

- [ ] **Step 3: Verify the pbxproj wiring is not dangling**

Run this and confirm every product listed in Step 2 has both a `PBXBuildFile` entry (`... in Frameworks`) and a matching `XCSwiftPackageProductDependency` entry — Xcode's own local-package UI does this correctly, but this is the same class of bug (a build-file reference with no matching build-file definition) discovered and fixed in `alric.xcodeproj` earlier this session, so verify it doesn't recur here:

```bash
cd ~/Projects/AICompleteChat
grep -c "PBXBuildFile" AICompleteChat.xcodeproj/project.pbxproj
grep -c "XCSwiftPackageProductDependency" AICompleteChat.xcodeproj/project.pbxproj
```

Both counts should be non-zero and every product name from Step 2 should appear in both.

- [ ] **Step 4: Write a smoke-test ContentView proving all six packages import and instantiate**

```swift
// ContentView.swift
import SwiftUI
import DesignFoundation
import DesignFoundationPro
import AIChatCore
import AIChatUI
import AIChatMLX
import AiPersona
import AiVoiceKit

struct ContentView: View {
    var body: some View {
        DFText("AICompleteChat", role: .title)
            .padding()
    }
}
```

```swift
// AICompleteChatApp.swift
import SwiftUI
import DesignFoundation

@main
struct AICompleteChatApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .dfThemePreset(.slate)
        }
    }
}
```

- [ ] **Step 5: Build and run to verify**

```bash
cd ~/Projects/AICompleteChat
xcodebuild -resolvePackageDependencies -project AICompleteChat.xcodeproj -scheme AICompleteChat
xcodebuild -project AICompleteChat.xcodeproj -scheme AICompleteChat -destination 'platform=macOS' -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`. Launch the built app and confirm a themed window with "AICompleteChat" text appears.

- [ ] **Step 6: Commit**

```bash
cd ~/Projects/AICompleteChat
cat > .gitignore << 'EOF'
.DS_Store
/.build
/DerivedData
xcuserdata/
*.xcuserstate
.swiftpm/configuration/registries.json
.swiftpm/xcode/package.xcworkspace/contents.xcworkspacedata
.netrc
EOF
git add -A
git commit -m "feat: scaffold AICompleteChat, wire all six local packages"
```

---

## Task 2: DesignFoundationPro — redesign AIChatModels.swift for on-device streaming

**Files:**
- Modify: `~/Projects/DesignFoundationPro/Sources/DesignFoundationPro/AIChat/AIChatModels.swift`
- Modify: `~/Projects/DesignFoundationPro/Tests/DesignFoundationProTests/AIChat/AIChatModelsTests.swift`
- Modify: `~/Projects/DesignFoundationPro/CHANGELOG.md`

**Interfaces:**
- Produces: `AIChatOnDeviceModel`, `AIChatModelLoadState`, `AIChatMessage.sourceMemoryFacts: [String]`, `MemorySnapshot` — every later DesignFoundationPro screen task consumes these exact names.
- Removes: `AIChatModel` static instances `.claude`, `.gpt4o`, `.gemini` (existing consumers must be updated — see Task 3).

- [ ] **Step 1: Write the failing test for the new model/load-state types**

```swift
// Tests/DesignFoundationProTests/AIChat/AIChatModelsTests.swift
import Testing
@testable import DesignFoundationPro

@Suite("AIChatOnDeviceModel")
struct AIChatOnDeviceModelTests {
    @Test("starts in notLoaded state")
    func startsNotLoaded() {
        let model = AIChatOnDeviceModel(
            id: "gemma-4-e4b-it-4bit",
            displayName: "Gemma 4 e4b",
            ramTier: "<16GB",
            loadState: .notLoaded
        )
        #expect(model.loadState == .notLoaded)
    }

    @Test("downloading state carries progress")
    func downloadingCarriesProgress() {
        let state = AIChatModelLoadState.downloading(progress: 0.42)
        guard case .downloading(let progress) = state else {
            Issue.record("expected .downloading")
            return
        }
        #expect(progress == 0.42)
    }
}

@Suite("AIChatMessage memory provenance")
struct AIChatMessageMemoryTests {
    @Test("defaults to no memory facts used")
    func defaultsEmpty() {
        let message = AIChatMessage(role: .assistant, content: "Hi")
        #expect(message.sourceMemoryFacts.isEmpty)
    }

    @Test("carries provided memory facts")
    func carriesProvidedFacts() {
        let message = AIChatMessage(role: .assistant, content: "Hi", sourceMemoryFacts: ["User prefers dark mode"])
        #expect(message.sourceMemoryFacts == ["User prefers dark mode"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd ~/Projects/DesignFoundationPro
swift test --filter AIChatOnDeviceModelTests
```

Expected: FAIL — `AIChatOnDeviceModel`/`AIChatModelLoadState` not defined.

- [ ] **Step 3: Replace the static cloud-model catalog with the on-device model + load state**

Remove the existing `AIChatModel` struct and its `.claude`/`.gpt4o`/`.gemini` static extension (`AIChatModels.swift:32-42` and `:117-121` in the current file), replacing with:

```swift
// AIChatModels.swift — replaces the AIChatModel struct and its static extension

public enum AIChatModelLoadState: Sendable, Equatable {
    case notLoaded
    case downloading(progress: Double)
    case ready
    case error(String)
}

public struct AIChatOnDeviceModel: Identifiable, Hashable, Sendable {
    public let id: String
    public var displayName: String
    public var ramTier: String
    public var loadState: AIChatModelLoadState

    public init(id: String, displayName: String, ramTier: String, loadState: AIChatModelLoadState) {
        self.id = id
        self.displayName = displayName
        self.ramTier = ramTier
        self.loadState = loadState
    }

    public static func == (lhs: AIChatOnDeviceModel, rhs: AIChatOnDeviceModel) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

public extension AIChatModelLoadState {
    static func == (lhs: AIChatModelLoadState, rhs: AIChatModelLoadState) -> Bool {
        switch (lhs, rhs) {
        case (.notLoaded, .notLoaded), (.ready, .ready): return true
        case (.downloading(let l), .downloading(let r)): return l == r
        case (.error(let l), .error(let r)): return l == r
        default: return false
        }
    }
}
```

Update `AIChatConversation` and `AIChatConversationGroup` to reference `model: AIChatOnDeviceModel` instead of `model: AIChatModel` (their `Sendable` structs unchanged otherwise). Update `AIChatMessage` to add the new field and initializer parameter:

```swift
public struct AIChatMessage: Identifiable, Sendable {
    public let id: UUID
    public var role: AIChatRole
    public var content: String
    public var timestamp: Date
    public var isStreaming: Bool
    public var sourceMemoryFacts: [String]

    public init(
        id: UUID = UUID(),
        role: AIChatRole,
        content: String,
        timestamp: Date = Date(),
        isStreaming: Bool = false,
        sourceMemoryFacts: [String] = []
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.isStreaming = isStreaming
        self.sourceMemoryFacts = sourceMemoryFacts
    }
}
```

Add the new memory-inspector-facing type:

```swift
public struct MemorySnapshot: Sendable {
    public var recentFacts: [String]
    public var entityCount: Int
    public var factCount: Int

    public init(recentFacts: [String], entityCount: Int, factCount: Int) {
        self.recentFacts = recentFacts
        self.entityCount = entityCount
        self.factCount = factCount
    }

    public static let empty = MemorySnapshot(recentFacts: [], entityCount: 0, factCount: 0)
}
```

Update `AIChatConversation.mockConversations(now:)` to build fixture data with `AIChatOnDeviceModel` instances instead of the removed `.claude`/`.gpt4o`/`.gemini` statics — replace every `model: .claude` / `model: .gpt4o` / `model: .gemini` reference with:

```swift
model: AIChatOnDeviceModel(id: "gemma-4-e4b-it-4bit", displayName: "Gemma 4 e4b", ramTier: "<16GB", loadState: .ready)
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd ~/Projects/DesignFoundationPro
swift test --filter AIChatOnDeviceModelTests
swift test --filter AIChatMessageMemoryTests
```

Expected: PASS.

- [ ] **Step 5: Add the CHANGELOG entry**

```markdown
## [2.0.0] — Unreleased

### Changed (Breaking)
- `AIChat` vertical redesigned around a single streaming on-device model. `AIChatModel`
  (static `.claude`/`.gpt4o`/`.gemini` cloud catalog) replaced by `AIChatOnDeviceModel`
  with `AIChatModelLoadState` (`.notLoaded`/`.downloading`/`.ready`/`.error`).
  `AIChatMessage` gains `sourceMemoryFacts: [String]` for memory provenance. New
  `MemorySnapshot` type for the Memory Inspector panel.
```

Insert this above the `## [1.0.0]` entry in `~/Projects/DesignFoundationPro/CHANGELOG.md`.

- [ ] **Step 6: Commit**

```bash
cd ~/Projects/DesignFoundationPro
git add Sources/DesignFoundationPro/AIChat/AIChatModels.swift Tests/DesignFoundationProTests/AIChat/AIChatModelsTests.swift CHANGELOG.md
git commit -m "feat(AIChat)!: replace cloud-model catalog with on-device model + load state

BREAKING CHANGE: AIChatModel removed, replaced by AIChatOnDeviceModel + AIChatModelLoadState"
```

---

## Task 3: DesignFoundationPro — fix AIChatDesignKit's model-color coupling

**Files:**
- Modify: `~/Projects/DesignFoundationPro/Sources/DesignFoundationPro/AIChat/AIChatDesignKit.swift:16-30`

**Interfaces:**
- Consumes: `AIChatOnDeviceModel` (Task 2).
- Produces: `AIChatPalette.modelColor(_:theme:)` with the same signature, now dependency-free of the removed `AIChatModel` statics — this compiles as soon as Task 2 lands; without this fix the package does not build after Task 2.

- [ ] **Step 1: Update `AIChatPalette.modelColor` to the new type**

The current implementation switches on `model.id` against `AIChatModel.claude.id` / `.gpt4o.id` / `.gemini.id`, which no longer exist after Task 2. Replace:

```swift
enum AIChatPalette {

    static func modelColor(_ model: AIChatOnDeviceModel, theme: DFTheme) -> Color {
        theme.colors.primary
    }

    static func bubbleBackground(role: AIChatRole, theme: DFTheme) -> Color {
        role == .user ? theme.colors.primary : theme.colors.surfaceElevated
    }

    static func bubbleForeground(role: AIChatRole, theme: DFTheme) -> Color {
        role == .user ? theme.colors.surface : theme.colors.textPrimary
    }
    // ... chipBorder and remaining members unchanged
}
```

A single on-device model has no per-model color-coding purpose anymore (that existed to visually distinguish Claude/GPT-4o/Gemini in the Compare screen) — `modelColor` now returns the theme's primary color unconditionally. Leave `bubbleBackground`/`bubbleForeground`/`chipBorder` and everything else in the file untouched.

- [ ] **Step 2: Build to verify the package compiles**

```bash
cd ~/Projects/DesignFoundationPro
swift build
```

Expected: builds with no errors mentioning `AIChatModel`, `.claude`, `.gpt4o`, or `.gemini`. (This will still show pre-existing errors in the five screen files until Task 4 onward lands — that's expected at this point in the plan; run `swift build 2>&1 | grep -c "error:"` before and after this step and confirm the count referencing `AIChatDesignKit.swift` specifically drops to zero.)

- [ ] **Step 3: Commit**

```bash
cd ~/Projects/DesignFoundationPro
git add Sources/DesignFoundationPro/AIChat/AIChatDesignKit.swift
git commit -m "fix(AIChat): update modelColor for single on-device model, no more cloud-model branching"
```

---

## Task 4: PersonaChatCoordinator — memory injection + ingestion (new type, TDD)

**Files:**
- Create: `~/Projects/AICompleteChat/AICompleteChat/Engine/PersonaChatCoordinator.swift`
- Create: `~/Projects/AICompleteChat/AICompleteChatTests/PersonaChatCoordinatorTests.swift`
- Create: `~/Projects/AICompleteChat/AICompleteChatTests/FakeChatProvider.swift`

**Interfaces:**
- Consumes: `ChatSession` (AIChatUI, real signatures from Task 1's package wiring), `ChatSession.KnowledgeRetrievalInjection(query:body:)`, `RetrievalService(store:factLimit:)`, `RetrievalService.sessionCompilation() -> String`, `RetrievalService.perTurnMemoryBlock(forQuery:excluding:limit:) -> String?`, `IngestionActor.shared.enqueue(_:provider:store:) -> [ExtractedFact]`, `ChatEpisode(userText:assistantText:occurredAt:)`, `MemoryProvider` protocol, `MemoryGraphStore(inMemory:)`, `PersonaStore` (`.name`, `.personality`), `PersonaPromptBuilder.identityPreamble(name:personality:)` / `.memorySection(_:)`.
- Produces: `PersonaChatCoordinator.send(_:)`, `PersonaChatCoordinator.init(session:store:retrieval:memoryProvider:personaStore:)`, `PersonaChatCoordinator.onMemoryUpdated: (() -> Void)?` — Task 6 (composition root) and Task 8 (thread screen wiring) call `send`/`init`; Task 6 also assigns `onMemoryUpdated` to bump `AppEnvironment`'s refresh signal so the Memory Inspector panel actually re-renders after background ingestion (see Task 6 Step 1 and Task 12 Step 3 for the two halves of this wiring).

- [ ] **Step 1: Write the fake chat provider test double**

```swift
// AICompleteChatTests/FakeChatProvider.swift
import Foundation
import AIChatCore

/// Yields a single fixed text event then completes — deterministic, no MLX model load required.
final class FakeChatProvider: ChatProvider, @unchecked Sendable {
    let id = "fake"
    let name = "Fake"
    var zeroResponseMessage: String { "no response" }

    var responseText: String = "Fake assistant response."
    private(set) var lastSystemPrompt: String?
    private(set) var lastMessages: [ChatMessage] = []

    func stream(
        messages: [ChatMessage],
        model: String,
        options: ChatRequestOptions
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        lastMessages = messages
        lastSystemPrompt = options.systemPrompt
        let text = responseText
        return AsyncThrowingStream { continuation in
            continuation.yield(.text(text))
            continuation.yield(.done)
            continuation.finish()
        }
    }

    func complete(
        messages: [ChatMessage],
        model: String,
        options: ChatRequestOptions
    ) async throws -> ChatCompletionResult {
        ChatCompletionResult(
            id: nil, model: model,
            message: ChatMessage(role: .assistant, content: responseText),
            usage: nil, finishReason: .stop
        )
    }
}
```

```swift
// AICompleteChatTests/PersonaChatCoordinatorTests.swift
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
        try await Task.sleep(nanoseconds: 200_000_000)

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
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(wasCalled)
    }
}

/// Never called in this test (no facts exist yet to extract from an empty in-memory store's
/// perspective before the turn completes) but required to satisfy the `MemoryProvider` protocol.
struct LocalMemoryProviderStub: MemoryProvider {
    func extractFacts(fromEpisode text: String) async throws -> [ExtractedFact] { [] }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd ~/Projects/AICompleteChat
xcodebuild test -project AICompleteChat.xcodeproj -scheme AICompleteChat -destination 'platform=macOS' -only-testing:AICompleteChatTests/PersonaChatCoordinatorTests 2>&1 | tail -30
```

Expected: FAIL — `PersonaChatCoordinator` not defined.

- [ ] **Step 3: Implement PersonaChatCoordinator**

```swift
// AICompleteChat/Engine/PersonaChatCoordinator.swift
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
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd ~/Projects/AICompleteChat
xcodebuild test -project AICompleteChat.xcodeproj -scheme AICompleteChat -destination 'platform=macOS' -only-testing:AICompleteChatTests/PersonaChatCoordinatorTests 2>&1 | tail -30
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/AICompleteChat
git add AICompleteChat/Engine/PersonaChatCoordinator.swift AICompleteChatTests/PersonaChatCoordinatorTests.swift AICompleteChatTests/FakeChatProvider.swift
git commit -m "feat: add PersonaChatCoordinator with memory injection + ingestion, TDD"
```

---

## Task 5: LocalMemoryProvider wiring + MemorySnapshot query helper

**Files:**
- Create: `~/Projects/AICompleteChat/AICompleteChat/Engine/MemorySnapshotProvider.swift`
- Create: `~/Projects/AICompleteChat/AICompleteChatTests/MemorySnapshotProviderTests.swift`

**Interfaces:**
- Consumes: `MemoryGraphStore.activeFacts() -> [FactEdge]`, `MemoryGraphStore.allEntities() -> [EntityNode]`, `FactEdge.factText: String` (existing property, verified in `MemoryGraphStore.swift`), `MemorySnapshot` (Task 2).
- Produces: `MemorySnapshotProvider.snapshot(from:limit:) -> MemorySnapshot` — Task 9 (Memory Inspector panel) calls this exact name.

- [ ] **Step 1: Write the failing test**

```swift
// AICompleteChatTests/MemorySnapshotProviderTests.swift
import Testing
import AiPersona
@testable import AICompleteChat

@MainActor
@Suite("MemorySnapshotProvider")
struct MemorySnapshotProviderTests {
    @Test("empty store produces empty snapshot")
    func emptyStoreProducesEmptySnapshot() {
        let store = MemoryGraphStore(inMemory: true)
        let snapshot = MemorySnapshotProvider.snapshot(from: store, limit: 5)
        #expect(snapshot.factCount == 0)
        #expect(snapshot.entityCount == 0)
        #expect(snapshot.recentFacts.isEmpty)
    }

    @Test("populated store reports counts and recent facts")
    func populatedStoreReportsCounts() {
        let store = MemoryGraphStore(inMemory: true)
        let subject = store.upsertEntity(name: "Daniel", summary: "Daniel", kind: .user, embedding: [])
        store.addFact(subjectID: subject.id, objectID: nil, predicate: "prefers", factText: "Daniel prefers dark mode", embedding: [])

        let snapshot = MemorySnapshotProvider.snapshot(from: store, limit: 5)
        #expect(snapshot.factCount == 1)
        #expect(snapshot.entityCount == 1)
        #expect(snapshot.recentFacts == ["Daniel prefers dark mode"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd ~/Projects/AICompleteChat
xcodebuild test -project AICompleteChat.xcodeproj -scheme AICompleteChat -destination 'platform=macOS' -only-testing:AICompleteChatTests/MemorySnapshotProviderTests 2>&1 | tail -30
```

Expected: FAIL — `MemorySnapshotProvider` not defined.

- [ ] **Step 3: Implement**

```swift
// AICompleteChat/Engine/MemorySnapshotProvider.swift
import Foundation
import AiPersona
import DesignFoundationPro

@MainActor
enum MemorySnapshotProvider {
    /// Reads directly from `store` — no separate cache, so this always reflects the latest
    /// ingested facts. Cheap enough to call on every Memory Inspector panel appearance.
    static func snapshot(from store: MemoryGraphStore, limit: Int = 10) -> MemorySnapshot {
        let facts = store.activeFacts()
        let recent = facts
            .sorted { $0.validAt > $1.validAt }
            .prefix(limit)
            .map(\.factText)
        return MemorySnapshot(
            recentFacts: Array(recent),
            entityCount: store.allEntities().count,
            factCount: facts.count
        )
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd ~/Projects/AICompleteChat
xcodebuild test -project AICompleteChat.xcodeproj -scheme AICompleteChat -destination 'platform=macOS' -only-testing:AICompleteChatTests/MemorySnapshotProviderTests 2>&1 | tail -30
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/AICompleteChat
git add AICompleteChat/Engine/MemorySnapshotProvider.swift AICompleteChatTests/MemorySnapshotProviderTests.swift
git commit -m "feat: add MemorySnapshotProvider for the Memory Inspector panel"
```

---

## Task 6: Composition root — wire MLXProvider, ChatSession, PersonaChatCoordinator, VoiceEngineMacOS

**Files:**
- Modify: `~/Projects/AICompleteChat/AICompleteChat/AICompleteChatApp.swift`
- Create: `~/Projects/AICompleteChat/AICompleteChat/Engine/AppEnvironment.swift`

**Interfaces:**
- Consumes: `MLXProvider()` (defaults to `recommendedModelId()` = `gemma-4-e4b-it-4bit`), `ChatSession(provider:model:options:)`, `PersonaChatCoordinator` (Task 4), `MemoryGraphStore.shared`, `RetrievalService(store:)`, `LocalMemoryProvider(mlxProvider:modelId:)`, `PersonaStore.shared`, `VoiceEngineMacOS(onCommandReceived:onEditRequested:)`.
- Produces: `AppEnvironment` (an `@MainActor final class` holding every engine object), injected into the view hierarchy via `.environment(appEnvironment)` — every screen task (7–11) reads its dependencies from this object.

- [ ] **Step 1: Implement AppEnvironment**

```swift
// AICompleteChat/Engine/AppEnvironment.swift
import Foundation
import Observation
import AIChatCore
import AIChatUI
import AIChatMLX
import AiPersona
import AiVoiceKit

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
}
```

- [ ] **Step 2: Wire into the app entry point**

```swift
// AICompleteChat/AICompleteChatApp.swift
import SwiftUI
import DesignFoundation

@main
struct AICompleteChatApp: App {
    @State private var appEnvironment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appEnvironment)
                .dfThemePreset(.slate)
        }
    }
}
```

- [ ] **Step 3: Build to verify**

```bash
cd ~/Projects/AICompleteChat
xcodebuild -project AICompleteChat.xcodeproj -scheme AICompleteChat -destination 'platform=macOS' -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
cd ~/Projects/AICompleteChat
git add AICompleteChat/Engine/AppEnvironment.swift AICompleteChat/AICompleteChatApp.swift
git commit -m "feat: wire MLXProvider, ChatSession, PersonaChatCoordinator, VoiceEngineMacOS in AppEnvironment"
```

---

## Task 7: DFAIChatRootView rebuild on DFThreeColumnShell

**Files:**
- Modify: `~/Projects/DesignFoundationPro/Sources/DesignFoundationPro/AIChat/DFAIChatRootView.swift`
- Modify: `~/Projects/DesignFoundationPro/Sources/DesignFoundationPro/AIChat/DFAIChatRootView+Previews.swift`

**Interfaces:**
- Consumes: `DFThreeColumnShell<Sidebar, ListView, Detail>(columnVisibility:sidebar:list:detail:)` (existing shell, verified signature), `groupConversations(_:now:)` (existing, unchanged), `AIChatOnDeviceModel` (Task 2).
- Produces: `DFAIChatRootView`'s public `init` gains a required `model: AIChatOnDeviceModel` binding/parameter (replacing the removed `selectedModel: AIChatModel` state) and an `onSend: (String) -> Void` closure the app supplies from `AppEnvironment.coordinator.send(_:)` — Task 8 and the app's `ContentView` depend on this exact call shape.

- [ ] **Step 1: Read the current root view before touching it**

```bash
cat -n ~/Projects/DesignFoundationPro/Sources/DesignFoundationPro/AIChat/DFAIChatRootView.swift
```

Identify every reference to the removed `AIChatModel`/`.claude`/`.gpt4o`/`.gemini` (there are `@State private var selectedModel: AIChatModel` at line 42, and Compare-column state at lines 46-48 slated for removal in Task 9) before making changes — this task only touches the sidebar/list/detail composition and the model-state type; leave the Compare-column state exactly as-is here (Task 9 handles removing/repurposing it) so this task's diff stays reviewable on its own.

- [ ] **Step 2: Rebuild the body on DFThreeColumnShell**

Replace `@State private var selectedModel: AIChatModel` with `@State private var model: AIChatOnDeviceModel`. Replace the root `body`'s top-level container with:

```swift
public var body: some View {
    DFThreeColumnShell(columnVisibility: $columnVisibility) {
        // Sidebar: conversation date groups
        List(selection: $activeConversationID) {
            ForEach(groupConversations(conversations)) { group in
                Section(group.label) {
                    ForEach(group.conversations) { conversation in
                        Text(conversation.title).tag(conversation.id as AIChatConversation.ID?)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    } list: {
        EmptyView() // list column intentionally empty — conversation rows live in the sidebar section per-group, matching a chat app's convention (Slack/Messages-style) rather than a separate flat list column
    } detail: {
        if let activeConversationID, let conversation = conversations.first(where: { $0.id == activeConversationID }) {
            DFAIChatThreadScreen(configuration: .init(
                conversation: conversation,
                model: model,
                onSend: { text in onSend(text) }
            ))
        } else {
            DFAIChatNewScreen(configuration: .init(model: model, onSend: { text, _ in onSend(text) }))
        }
    }
    .environment(\.dfTheme, .workspace)
    .environment(\.dfUseDesktopDensity, DFLayout.useDesktopLayout(horizontalSizeClass: sizeClass))
    .dfToastHost()
}
```

Add `@State private var columnVisibility: NavigationSplitViewVisibility = .all` alongside the existing `@State` properties. Remove `@State private var isStreaming: Bool` (Task 8's thread screen reads streaming state directly from `AIChatMessage.isStreaming` per-message, not from a single root-level flag) and `@State private var selectedTab`/`sidebarSelection`/`DFAIChatNav` (the tab-based nav this view used for switching between Thread/Compare is replaced entirely by the three-column shell — Task 9 removes the Compare tab's remaining references).

- [ ] **Step 3: Update the public initializer**

```swift
public init(
    conversations: [AIChatConversation] = AIChatConversation.mockConversations(),
    model: AIChatOnDeviceModel,
    onSend: @escaping (String) -> Void
) {
    self._conversations = State(initialValue: conversations)
    self._model = State(initialValue: model)
    self.onSend = onSend
}

private let onSend: (String) -> Void
```

- [ ] **Step 4: Update the preview file to the new initializer**

```swift
// DFAIChatRootView+Previews.swift
#Preview("Root — with conversations") {
    DFAIChatRootView(
        model: AIChatOnDeviceModel(id: "gemma-4-e4b-it-4bit", displayName: "Gemma 4 e4b", ramTier: "<16GB", loadState: .ready),
        onSend: { _ in }
    )
    .environment(\.dfUseDesktopDensity, true)
}

#Preview("Root — empty, no conversations") {
    DFAIChatRootView(
        conversations: [],
        model: AIChatOnDeviceModel(id: "gemma-4-e4b-it-4bit", displayName: "Gemma 4 e4b", ramTier: "<16GB", loadState: .ready),
        onSend: { _ in }
    )
    .environment(\.dfUseDesktopDensity, true)
}
```

- [ ] **Step 5: Build DesignFoundationPro to verify**

```bash
cd ~/Projects/DesignFoundationPro
swift build 2>&1 | grep -c "error:"
```

Expected: errors referencing `DFAIChatRootView.swift` are gone (errors in `DFAIChatThreadScreen.swift`/`DFAIChatCompareScreen.swift`/`DFAIChatNewScreen.swift`/`DFAIChatSettingsSheet.swift` are expected until Tasks 8–11 land — confirm the *count* has dropped, not that it's zero).

- [ ] **Step 6: Commit**

```bash
cd ~/Projects/DesignFoundationPro
git add Sources/DesignFoundationPro/AIChat/DFAIChatRootView.swift Sources/DesignFoundationPro/AIChat/DFAIChatRootView+Previews.swift
git commit -m "feat(AIChat)!: rebuild DFAIChatRootView on DFThreeColumnShell for single-model chat"
```

---

## Task 8: DFAIChatThreadScreen — voice input + memory provenance

**Files:**
- Modify: `~/Projects/DesignFoundationPro/Sources/DesignFoundationPro/AIChat/DFAIChatThreadScreen.swift`
- Modify: `~/Projects/DesignFoundationPro/Tests/DesignFoundationProTests/AIChat/DFAIChatThreadScreenTests.swift`

**Interfaces:**
- Consumes: `DFRightInspectorShell<Content, Inspector>(isInspectorVisible:inspectorWidth:content:inspector:)` (existing shell, verified signature), `AIChatMessage.sourceMemoryFacts` (Task 2), `VoiceEngineMacOS.state`/`.transcript` (read-only, from `AppEnvironment` passed via the app's own wiring — see Note below).
- Produces: `DFAIChatThreadScreen.Configuration` gains `voiceState: VoiceEngineState`, `voiceTranscript: String`, `onMicTapped: () -> Void`, `memorySnapshot: MemorySnapshot`, and `isInspectorVisible: Binding<Bool>` — Task 7's root view call site (Step 2 above) must be updated once this task lands to pass these (tracked as this task's own follow-up sub-step, not a new task, since the two are one reviewable unit of "thread screen now supports voice + inspector").

**Note on voice state:** DesignFoundationPro has no dependency on AiVoiceKit (it's a general-purpose UI package, not app-specific) — it cannot import `AiVoiceKit` or reference `VoiceEngineState` directly. Instead, this task adds a package-local, minimal mirror type so the screen stays consumable by anyone, and `AICompleteChat`'s call site (Step 5 below) maps `VoiceEngineState` onto it.

- [ ] **Step 1: Add a package-local recording-state type**

```swift
// AIChatModels.swift — append
public enum AIChatVoiceState: Sendable, Equatable {
    case idle
    case recording
    case processing
}
```

- [ ] **Step 2: Read the current thread screen before touching it**

```bash
cat -n ~/Projects/DesignFoundationPro/Sources/DesignFoundationPro/AIChat/DFAIChatThreadScreen.swift
```

- [ ] **Step 3: Extend Configuration and wrap the body in DFRightInspectorShell**

Add to `DFAIChatThreadScreen.Configuration` (alongside the existing `onSend` and other stored properties):

```swift
public var voiceState: AIChatVoiceState
public var voiceTranscript: String
public var onMicTapped: @MainActor () -> Void
public var memorySnapshot: MemorySnapshot
public var isInspectorVisible: Binding<Bool>

public init(
    // ...existing parameters...
    voiceState: AIChatVoiceState = .idle,
    voiceTranscript: String = "",
    onMicTapped: @escaping @MainActor () -> Void = {},
    memorySnapshot: MemorySnapshot = .empty,
    isInspectorVisible: Binding<Bool> = .constant(false)
) {
    // ...existing assignments...
    self.voiceState = voiceState
    self.voiceTranscript = voiceTranscript
    self.onMicTapped = onMicTapped
    self.memorySnapshot = memorySnapshot
    self.isInspectorVisible = isInspectorVisible
}
```

Wrap the existing `body` content in the shell:

```swift
public var body: some View {
    DFRightInspectorShell(isInspectorVisible: configuration.isInspectorVisible) {
        threadContent // the screen's existing message-list + input-bar body, renamed as a computed property, unchanged internally except for Step 4 below
    } inspector: {
        MemoryInspectorPanel(snapshot: configuration.memorySnapshot)
    }
}
```

- [ ] **Step 4: Add the mic button and live transcript to the input bar**

Find the existing input `HStack` around the `TextField`/`onSubmit` call (near line 311 in the current file, where `configuration.onSend(text)` is invoked). Add a mic button before the send button:

```swift
Button {
    configuration.onMicTapped()
} label: {
    Image(systemName: configuration.voiceState == .recording ? "mic.fill" : "mic")
        .foregroundStyle(configuration.voiceState == .recording ? theme.colors.error : theme.colors.textSecondary)
}
.accessibilityLabel(configuration.voiceState == .recording ? "Stop recording" : "Start voice dictation")

if configuration.voiceState == .recording, !configuration.voiceTranscript.isEmpty {
    Text(configuration.voiceTranscript)
        .font(.caption)
        .foregroundStyle(theme.colors.textSecondary)
        .lineLimit(1)
}
```

- [ ] **Step 5: Add the MemoryInspectorPanel content view (new file, same directory)**

```swift
// Sources/DesignFoundationPro/AIChat/MemoryInspectorPanel.swift
import SwiftUI
import DesignFoundation

struct MemoryInspectorPanel: View {
    @Environment(\.dfTheme) private var theme
    let snapshot: MemorySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.md) {
            DFText("Memory", role: .headline)
            HStack {
                DFBadge("\(snapshot.entityCount) entities", style: .subtle)
                DFBadge("\(snapshot.factCount) facts", style: .subtle)
            }
            if snapshot.recentFacts.isEmpty {
                DFEmptyState(
                    title: "No memories yet",
                    message: "Facts you mention in conversation will appear here.",
                    systemImage: "brain"
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: theme.spacing.sm) {
                        ForEach(snapshot.recentFacts, id: \.self) { fact in
                            Text(fact).font(.caption)
                        }
                    }
                }
            }
        }
        .padding(theme.spacing.md)
    }
}
```

(`DFEmptyState`'s exact initializer parameters must be verified against `~/Projects/DesignFoundation/Sources/DesignFoundation/Supplementary/EmptyState/` before this compiles — read that file's public `init` first and adjust the call above to match; do not guess the parameter names.)

- [ ] **Step 6: Thread the new parameters through DFAIChatRootView, which is what actually instantiates DFAIChatThreadScreen**

`DFAIChatRootView` (Task 7) is the only place that constructs `DFAIChatThreadScreen(configuration:)` — it doesn't yet know about `voiceState`/`voiceTranscript`/`onMicTapped`/`memorySnapshot`/`isInspectorVisible`, so those would otherwise have no way to reach the thread screen. Extend `DFAIChatRootView`'s public `init` (in `DFAIChatRootView.swift`, from Task 7) with the same five parameters, all defaulted so Task 7's existing call sites/previews keep compiling unchanged:

```swift
public init(
    conversations: [AIChatConversation] = AIChatConversation.mockConversations(),
    model: AIChatOnDeviceModel,
    onSend: @escaping (String) -> Void,
    voiceState: AIChatVoiceState = .idle,
    voiceTranscript: String = "",
    onMicTapped: @escaping @MainActor () -> Void = {},
    memorySnapshot: MemorySnapshot = .empty,
    isInspectorVisible: Binding<Bool> = .constant(false)
) {
    self._conversations = State(initialValue: conversations)
    self._model = State(initialValue: model)
    self.onSend = onSend
    self.voiceState = voiceState
    self.voiceTranscript = voiceTranscript
    self.onMicTapped = onMicTapped
    self.memorySnapshot = memorySnapshot
    self.isInspectorVisible = isInspectorVisible
}

private let voiceState: AIChatVoiceState
private let voiceTranscript: String
private let onMicTapped: @MainActor () -> Void
private let memorySnapshot: MemorySnapshot
private let isInspectorVisible: Binding<Bool>
```

Update the `detail` closure (inside `body`, from Task 7 Step 2) to forward them into `DFAIChatThreadScreen`'s `Configuration`:

```swift
DFAIChatThreadScreen(configuration: .init(
    conversation: conversation,
    model: model,
    onSend: { text in onSend(text) },
    voiceState: voiceState,
    voiceTranscript: voiceTranscript,
    onMicTapped: onMicTapped,
    memorySnapshot: memorySnapshot,
    isInspectorVisible: isInspectorVisible
))
```

- [ ] **Step 7: Update DFAIChatThreadScreenTests.swift and previews for the new Configuration shape**

```bash
cat -n ~/Projects/DesignFoundationPro/Tests/DesignFoundationProTests/AIChat/DFAIChatThreadScreenTests.swift
```

Update every `Configuration(...)` call site in that test file and in `DFAIChatThreadScreen+Previews.swift` to pass the new parameters (or rely on their defaults where a test doesn't care about voice/memory state) — same mechanical update pattern as Task 7 Step 4.

- [ ] **Step 8: Build to verify**

```bash
cd ~/Projects/DesignFoundationPro
swift build 2>&1 | grep -c "error:"
```

Expected: errors referencing `DFAIChatThreadScreen.swift` and `DFAIChatRootView.swift` are gone.

- [ ] **Step 9: Commit**

```bash
cd ~/Projects/DesignFoundationPro
git add Sources/DesignFoundationPro/AIChat/DFAIChatThreadScreen.swift Sources/DesignFoundationPro/AIChat/DFAIChatThreadScreen+Previews.swift Sources/DesignFoundationPro/AIChat/DFAIChatRootView.swift Sources/DesignFoundationPro/AIChat/MemoryInspectorPanel.swift Sources/DesignFoundationPro/AIChat/AIChatModels.swift Tests/DesignFoundationProTests/AIChat/DFAIChatThreadScreenTests.swift
git commit -m "feat(AIChat): add voice input affordance + Memory Inspector to DFAIChatThreadScreen, threaded through DFAIChatRootView"
```

---

## Task 9: Repurpose DFAIChatCompareScreen out of the vertical, delete Compare-column state from RootView

**Files:**
- Modify: `~/Projects/DesignFoundationPro/Sources/DesignFoundationPro/AIChat/DFAIChatRootView.swift`
- Delete: `~/Projects/DesignFoundationPro/Sources/DesignFoundationPro/AIChat/DFAIChatCompareScreen.swift`
- Delete: `~/Projects/DesignFoundationPro/Sources/DesignFoundationPro/AIChat/DFAIChatCompareScreen+Previews.swift`
- Delete: `~/Projects/DesignFoundationPro/Tests/DesignFoundationProTests/AIChat/DFAIChatCompareScreenTests.swift`

**Interfaces:**
- Produces: `DFAIChatRootView` with zero remaining references to `DFAIChatCompareScreen`, `DFAIChatCompareColumn`, `leftCompareColumn`/`rightCompareColumn`/`compareSyncScroll` state, or `DFAIChatNav` tab enum.

- [ ] **Step 1: Remove the leftover Compare-column state and nav enum from DFAIChatRootView**

Task 7 already replaced the root view's `body` and left the old `leftCompareColumn`/`rightCompareColumn`/`compareSyncScroll` `@State` declarations and the `DFAIChatNav` enum (if defined in this file) in place, deliberately, so Task 7's diff stayed reviewable on its own. Remove those now — grep first to confirm you're removing every reference, not just the declarations:

```bash
grep -n "CompareColumn\|compareSyncScroll\|DFAIChatNav" ~/Projects/DesignFoundationPro/Sources/DesignFoundationPro/AIChat/DFAIChatRootView.swift
```

Delete every matched line/declaration.

- [ ] **Step 2: Delete the Compare screen files**

**Deviation from the design spec, flagged for the user's awareness:** the spec's intent was to repurpose `DFAIChatCompareScreen`'s "existing side-by-side layout primitives" into the Memory Inspector's content. Having now read the full file, that doesn't hold up — every reusable piece in it (`DFAIChatCompareColumn`, the `leftModel`/`rightModel` pickers, `AIChatMetricBadge` token/response-time badges, `syncScroll`, the two-column `HStack` of full chat-message transcripts) is built specifically for diffing two models' *message streams* side by side. There is no facts-list, entity-count, or single-column primitive anywhere in it to extract. Task 8 already built `MemoryInspectorPanel` from scratch instead, using `DFText`/`DFBadge`/`DFEmptyState` directly — which is what actually serves the panel's real content (a flat list of facts + counts), not a forced reuse of two-model diff layout code. Delete rather than carry dead weight:

```bash
cd ~/Projects/DesignFoundationPro
git rm Sources/DesignFoundationPro/AIChat/DFAIChatCompareScreen.swift
git rm Sources/DesignFoundationPro/AIChat/DFAIChatCompareScreen+Previews.swift
git rm Tests/DesignFoundationProTests/AIChat/DFAIChatCompareScreenTests.swift
```

- [ ] **Step 3: Build to verify no dangling references remain**

```bash
cd ~/Projects/DesignFoundationPro
grep -rln "DFAIChatCompareScreen\|DFAIChatCompareColumn" Sources/ Tests/
swift build 2>&1 | grep -c "error:"
```

Expected: the `grep` returns no files; build error count referencing the AIChat vertical continues to drop (Task 10/11 remain).

- [ ] **Step 4: Commit**

```bash
cd ~/Projects/DesignFoundationPro
git add -A
git commit -m "refactor(AIChat)!: remove DFAIChatCompareScreen, replaced by MemoryInspectorPanel (Task 8)"
```

---

## Task 10: DFAIChatNewScreen — first-run, model load, and permission states

**Files:**
- Modify: `~/Projects/DesignFoundationPro/Sources/DesignFoundationPro/AIChat/DFAIChatNewScreen.swift`
- Modify: `~/Projects/DesignFoundationPro/Sources/DesignFoundationPro/AIChat/DFAIChatNewScreen+Previews.swift`
- Modify: `~/Projects/DesignFoundationPro/Tests/DesignFoundationProTests/AIChat/DFAIChatNewScreenTests.swift`

**Interfaces:**
- Consumes: `AIChatModelLoadState` (Task 2).
- Produces: `DFAIChatNewScreen.Configuration` gains `loadState: AIChatModelLoadState`, `onRetryLoad: () -> Void`, `micPermissionGranted: Bool`, `accessibilityPermissionGranted: Bool`, `onOpenSystemSettings: () -> Void`.

- [ ] **Step 1: Read the current new-conversation screen before touching it**

```bash
cat -n ~/Projects/DesignFoundationPro/Sources/DesignFoundationPro/AIChat/DFAIChatNewScreen.swift
```

- [ ] **Step 2: Extend Configuration and branch the body on load state**

```swift
public var loadState: AIChatModelLoadState
public var onRetryLoad: @MainActor () -> Void
public var micPermissionGranted: Bool
public var accessibilityPermissionGranted: Bool
public var onOpenSystemSettings: @MainActor () -> Void
```

At the top of `body`, branch before rendering the existing starter-prompts content:

```swift
public var body: some View {
    switch configuration.loadState {
    case .notLoaded:
        DFEmptyState(title: "Preparing on-device model", message: "This starts automatically.", systemImage: "cpu")
    case .downloading(let progress):
        VStack(spacing: theme.spacing.md) {
            DFText("Downloading Gemma 4 e4b…", role: .headline)
            ProgressView(value: progress)
                .frame(maxWidth: 320)
            DFText("\(Int(progress * 100))%", role: .caption)
        }
    case .error(let message):
        VStack(spacing: theme.spacing.md) {
            DFIcon(systemName: "exclamationmark.triangle", color: theme.colors.error)
            DFText("Model failed to load", role: .headline)
            DFText(message, role: .body)
            DFButton("Retry") { configuration.onRetryLoad() }
        }
    case .ready:
        readyContent // the screen's existing starter-prompt body, renamed as a computed property
    }
}
```

Above (or below) `readyContent`, add permission prompts shown only when `loadState == .ready` and a permission is missing:

```swift
if !configuration.micPermissionGranted {
    DFBanner(
        title: "Microphone access needed",
        message: "Voice dictation requires microphone permission.",
        style: .warning,
        action: .init(label: "Open Settings", handler: configuration.onOpenSystemSettings)
    )
}
if !configuration.accessibilityPermissionGranted {
    DFBanner(
        title: "Accessibility access needed",
        message: "Voice hotkeys and typed output require Accessibility permission.",
        style: .warning,
        action: .init(label: "Open Settings", handler: configuration.onOpenSystemSettings)
    )
}
```

(`DFBanner`'s exact initializer must be verified against `~/Projects/DesignFoundation/Sources/DesignFoundation/Supplementary/Banner/` before this compiles — read that file's public `init` first and adjust the call above to match, same as the `DFEmptyState` note in Task 8.)

- [ ] **Step 3: Update DFAIChatNewScreenTests.swift and previews for the new Configuration shape**

Same mechanical update pattern as Task 7 Step 4 and Task 8 Step 6 — update every `Configuration(...)` call site. Add at least one preview per new state (`.notLoaded`, `.downloading(progress: 0.4)`, `.error("...")`, `.ready` with a permission banner showing) per the Global Constraint on non-happy states.

- [ ] **Step 4: Build to verify**

```bash
cd ~/Projects/DesignFoundationPro
swift build 2>&1 | grep -c "error:"
```

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/DesignFoundationPro
git add Sources/DesignFoundationPro/AIChat/DFAIChatNewScreen.swift Sources/DesignFoundationPro/AIChat/DFAIChatNewScreen+Previews.swift Tests/DesignFoundationProTests/AIChat/DFAIChatNewScreenTests.swift
git commit -m "feat(AIChat): add model-load and permission non-happy states to DFAIChatNewScreen"
```

---

## Task 11: DFAIChatSettingsSheet — voice hotkeys, model info, memory management

**Files:**
- Modify: `~/Projects/DesignFoundationPro/Sources/DesignFoundationPro/AIChat/DFAIChatSettingsSheet.swift`
- Modify: `~/Projects/DesignFoundationPro/Sources/DesignFoundationPro/AIChat/DFAIChatSettingsSheet+Previews.swift`
- Modify: `~/Projects/DesignFoundationPro/Tests/DesignFoundationProTests/AIChat/DFAIChatSettingsSheetTests.swift`

**Interfaces:**
- Consumes: `AIChatOnDeviceModel` (Task 2), `MemorySnapshot` (Task 2).
- Produces: `DFAIChatSettingsSheet.Configuration` gains `model: AIChatOnDeviceModel`, `onReloadModel: () -> Void`, `memorySnapshot: MemorySnapshot`, `onClearMemory: () -> Void`, `onExportMemory: () -> Void`, and a `voiceHotkeysContent: AnyView` slot (see Note below).

**Note on voice hotkeys:** same package-boundary issue as Task 8 — DesignFoundationPro cannot import `AiVoiceKit`. Rather than mirror `VoiceHotkeyManager`'s full configuration surface into DesignFoundationPro (disproportionate for one settings section), this sheet accepts an injected `AnyView` for that one section, letting `AICompleteChat` supply its own hotkey-recording UI (reusing the exact same settings-group pattern already shipped in Alric's `VoiceHotkeysSettingsView`) without DesignFoundationPro needing to know `AiVoiceKit` exists.

- [ ] **Step 1: Read the current settings sheet before touching it**

```bash
cat -n ~/Projects/DesignFoundationPro/Sources/DesignFoundationPro/AIChat/DFAIChatSettingsSheet.swift
```

Remove `@State private var selectedModel: AIChatModel` (references the removed type) — the model is now display-only info from `configuration.model`, not user-selectable (Global Constraint: single on-device model, no picker).

- [ ] **Step 2: Extend Configuration and add new sections to the body**

```swift
public var model: AIChatOnDeviceModel
public var onReloadModel: @MainActor () -> Void
public var memorySnapshot: MemorySnapshot
public var onClearMemory: @MainActor () -> Void
public var onExportMemory: @MainActor () -> Void
public var voiceHotkeysContent: AnyView
```

Add to the body (alongside the existing system-prompt/temperature/max-tokens sections, which stay unchanged):

```swift
Section("Model") {
    LabeledContent("Model", value: configuration.model.displayName)
    LabeledContent("Device tier", value: configuration.model.ramTier)
    DFButton("Reload model", style: .outlined) { configuration.onReloadModel() }
}

Section("Voice") {
    configuration.voiceHotkeysContent
}

Section("Memory") {
    LabeledContent("Entities", value: "\(configuration.memorySnapshot.entityCount)")
    LabeledContent("Facts", value: "\(configuration.memorySnapshot.factCount)")
    DFButton("Export memory", style: .outlined) { configuration.onExportMemory() }
    DFButton("Clear memory", style: .outlined) { configuration.onClearMemory() }
        .foregroundStyle(theme.colors.error)
}
```

- [ ] **Step 3: Update DFAIChatSettingsSheetTests.swift and previews for the new Configuration shape**

Same mechanical update pattern as prior tasks. For preview/test call sites, pass `voiceHotkeysContent: AnyView(EmptyView())` — the sheet doesn't need real hotkey UI to be previewable in isolation, only `AICompleteChat`'s own call site (Task 12) needs the real content.

- [ ] **Step 4: Build to verify**

```bash
cd ~/Projects/DesignFoundationPro
swift build 2>&1 | grep -c "error:"
```

Expected: 0 — this is the last DesignFoundationPro AIChat-vertical file with outstanding errors from Task 2's breaking change.

- [ ] **Step 5: Run the full DesignFoundationPro test suite**

```bash
cd ~/Projects/DesignFoundationPro
swift test 2>&1 | tail -40
```

Expected: all tests pass, including the Task 2/7/8/9/10/11 updates.

- [ ] **Step 6: Commit**

```bash
cd ~/Projects/DesignFoundationPro
git add Sources/DesignFoundationPro/AIChat/DFAIChatSettingsSheet.swift Sources/DesignFoundationPro/AIChat/DFAIChatSettingsSheet+Previews.swift Tests/DesignFoundationProTests/AIChat/DFAIChatSettingsSheetTests.swift
git commit -m "feat(AIChat): add model info, voice hotkey slot, and memory management to settings sheet"
```

---

## Task 12: AICompleteChat — wire the redesigned vertical into ContentView, add Voice Hotkeys settings content

**Files:**
- Modify: `~/Projects/AICompleteChat/AICompleteChat/ContentView.swift`
- Create: `~/Projects/AICompleteChat/AICompleteChat/Settings/VoiceHotkeysSettingsContent.swift`
- Modify: `~/Projects/AICompleteChat/AICompleteChat/AICompleteChatApp.swift`

**Interfaces:**
- Consumes: `AppEnvironment` (Task 6), `DFAIChatRootView` (Task 7), `DFAIChatSettingsSheet` (Task 11), `VoiceHotkeyManager` (AiVoiceKit — read `~/xCodeProjects/NerdSnipe-Inc-Packages/AiVoiceKit/Sources/AiVoiceKit/macOS/Hotkeys/VoiceHotkeyManager.swift`'s public API before writing this content view, and reuse the same settings-group pattern already shipped in Alric's `alric/Features/Voice/Settings/VoiceHotkeysSettingsView.swift` — read that file too, since it's a proven, shipped reference implementation of exactly this UI against the exact same `VoiceHotkeyManager` API).

- [ ] **Step 1: Read both reference files before writing this task's code**

```bash
cat -n ~/xCodeProjects/NerdSnipe-Inc-Packages/AiVoiceKit/Sources/AiVoiceKit/macOS/Hotkeys/VoiceHotkeyManager.swift
cat -n ~/xCodeProjects/Alric-Platform/alric-compat-ios26/alric/Features/Voice/Settings/VoiceHotkeysSettingsView.swift
```

- [ ] **Step 2: Implement VoiceHotkeysSettingsContent**

Port the shortcut-row UI pattern from Alric's `VoiceHotkeysSettingsView` (dictation/command/edit/cancel/paste-last shortcut rows + activation-mode picker), adapted to read from `appEnvironment.voiceEngine` instead of however Alric wires it — the exact adaptation depends on what Step 1's read of `VoiceHotkeysSettingsView.swift` shows for its current data source (likely `VoiceSettingsStore.shared` directly, in which case this file is nearly a verbatim copy with the import path adjusted). Write the actual copied-and-adapted implementation here once Step 1 is done — do not stub this out.

- [ ] **Step 3: Wire ContentView to the redesigned root view + settings sheet, with real voice/memory reactivity**

`VoiceEngineMacOS` is a Combine `ObservableObject` (`@Published var state`/`.transcript`), not an `@Observable` type — reading it only through the `@Observable AppEnvironment` wrapper does **not** make SwiftUI re-render when `state`/`.transcript` change, because Observation tracks access to `@Observable`-macro'd properties, not a nested object's own `@Published` changes. `ContentView` must hold its own `@ObservedObject` reference to `appEnvironment.voiceEngine` for that specific subscription:

```swift
// ContentView.swift
import SwiftUI
import DesignFoundationPro
import AiVoiceKit

struct ContentView: View {
    @Environment(AppEnvironment.self) private var appEnvironment
    @ObservedObject private var voiceEngine: VoiceEngineMacOS
    @State private var showSettings = false
    @State private var isInspectorVisible = false

    init() {
        // Placeholder engine for the property initializer; replaced immediately in .task below
        // once appEnvironment is available — SwiftUI doesn't allow reading @Environment inside init.
        self._voiceEngine = ObservedObject(wrappedValue: VoiceEngineMacOS(onCommandReceived: { _ in }))
    }

    var body: some View {
        DFAIChatRootView(
            model: currentModel,
            onSend: { text in appEnvironment.coordinator.send(text) },
            voiceState: mappedVoiceState,
            voiceTranscript: voiceEngine.transcript,
            onMicTapped: { Task { await toggleDictation() } },
            memorySnapshot: currentMemorySnapshot,
            isInspectorVisible: $isInspectorVisible
        )
        .task {
            // Re-point @ObservedObject at the real, shared instance from AppEnvironment now
            // that @Environment is readable — see init()'s comment above.
            voiceEngine = appEnvironment.voiceEngine
        }
        .sheet(isPresented: $showSettings) {
            DFAIChatSettingsSheet(configuration: .init(
                model: currentModel,
                onReloadModel: { /* Task 13 wires actual reload */ },
                memorySnapshot: currentMemorySnapshot,
                onClearMemory: { /* Task 13 wires actual clear */ },
                onExportMemory: { /* Task 13 wires actual export */ },
                voiceHotkeysContent: AnyView(VoiceHotkeysSettingsContent(voiceEngine: appEnvironment.voiceEngine))
            ))
        }
    }

    private var currentModel: AIChatOnDeviceModel {
        AIChatOnDeviceModel(
            id: MLXProvider.recommendedModelId(),
            displayName: "Gemma 4 e4b",
            ramTier: "<16GB",
            loadState: .ready // Task 13 replaces this with real MLXProvider load-state tracking
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
```

`voiceEngine` above must be a `var` (not `let`) `@ObservedObject` property for the `.task` reassignment to compile — SwiftUI's `@ObservedObject` property wrapper supports reassignment; it does not retain state across the reassignment itself, which is fine here since the placeholder instance is discarded immediately at first render, before any UI has attached to it.

Memory Inspector visibility (`isInspectorVisible`) is a plain local `@State` bool the user toggles from the thread screen's own inspector-toggle affordance (already part of `DFRightInspectorShell`'s standard chrome from Task 8) — no additional wiring needed here.

- [ ] **Step 4: Update AICompleteChatApp.swift to use the @Observable environment correctly**

```swift
// AICompleteChatApp.swift
import SwiftUI
import DesignFoundation

@main
struct AICompleteChatApp: App {
    @State private var appEnvironment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appEnvironment)
                .dfThemePreset(.slate)
        }
    }
}
```

- [ ] **Step 5: Build and launch to verify**

```bash
cd ~/Projects/AICompleteChat
xcodebuild -project AICompleteChat.xcodeproj -scheme AICompleteChat -destination 'platform=macOS' -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`. Launch the app: confirm the three-column shell renders, a conversation can be sent (typed text → `coordinator.send` → streamed response appears), and the settings sheet opens showing model/voice/memory sections.

- [ ] **Step 6: Commit**

```bash
cd ~/Projects/AICompleteChat
git add AICompleteChat/ContentView.swift AICompleteChat/Settings/VoiceHotkeysSettingsContent.swift AICompleteChat/AICompleteChatApp.swift
git commit -m "feat: wire redesigned AIChat vertical + voice hotkeys settings into ContentView"
```

---

## Task 13: Real model-load-state tracking, permission checks, and memory clear/export wiring

**Files:**
- Modify: `~/Projects/AICompleteChat/AICompleteChat/Engine/AppEnvironment.swift`
- Modify: `~/Projects/AICompleteChat/AICompleteChat/ContentView.swift`

**Interfaces:**
- Consumes: `MLXProvider.loadModel(progressHandler:)`, `MemoryGraphStore` (needs a way to clear — read `MemoryGraphStore.swift` fully for a `deleteAll`/reset method; if none exists, this task must add one to AiPersona first, following the same TDD pattern as Task 5), `NotionExportService`/`GraphVisualizationExport` (AiPersona, for the export action).
- Produces: `AppEnvironment.modelLoadState: AIChatModelLoadState` (observable), replacing Task 12's hardcoded `.ready` placeholder — this is the task that removes that placeholder, so Task 12 is not a stopping point on its own for a truthful "no placeholders" build.

- [ ] **Step 1: Add observable load-state tracking to AppEnvironment**

```swift
// AppEnvironment.swift — add
var modelLoadState: AIChatModelLoadState = .notLoaded

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
```

Call `await appEnvironment.loadModel()` from a `.task` modifier on `ContentView`'s body (added in Step 3 below) so it starts automatically at launch.

- [ ] **Step 2: Check for a MemoryGraphStore reset method; add one via TDD if missing**

```bash
grep -n "func delete\|func clear\|func reset" ~/xCodeProjects/NerdSnipe-Inc-Packages/AiPersona/Sources/AiPersona/Memory/MemoryGraphStore.swift
```

If nothing matches, add (in `~/xCodeProjects/NerdSnipe-Inc-Packages/AiPersona`, with a corresponding test in `Tests/AiPersonaTests/`, following that package's own existing test conventions — read one existing `MemoryGraphStore` test file first to match its style before adding):

```swift
/// Deletes every entity, episode, and fact — irreversible. Used by a host app's "clear memory"
/// settings action.
public func deleteAll() {
    for entity in allEntities() { context.delete(entity) }
    for fact in allFacts() { context.delete(fact) }
    try? context.save()
}
```

- [ ] **Step 3: Wire real reload/clear/export/model-state into ContentView**

Replace Task 12's placeholder closures and hardcoded `currentModel`:

```swift
private var currentModel: AIChatOnDeviceModel {
    AIChatOnDeviceModel(
        id: MLXProvider.recommendedModelId(),
        displayName: "Gemma 4 e4b",
        ramTier: "<16GB",
        loadState: appEnvironment.modelLoadState
    )
}
```

```swift
onReloadModel: { Task { await appEnvironment.loadModel() } },
onClearMemory: { appEnvironment.memoryStore.deleteAll() },
onExportMemory: {
    let export = GraphVisualizationExport.build(
        fromEntities: appEnvironment.memoryStore.allEntities(),
        activeFacts: appEnvironment.memoryStore.activeFacts()
    )
    // Task scope ends at producing the export payload; wiring it to a save panel is a UI
    // detail for whoever picks this up next — NSSavePanel + JSONEncoder(export) is the
    // straightforward path, matching how the rest of this app writes files.
},
```

Add the `.task` modifier that starts model loading automatically:

```swift
var body: some View {
    DFAIChatRootView(/* ... */)
        .task { await appEnvironment.loadModel() }
        .sheet(/* ... */)
}
```

- [ ] **Step 4: Build and manually verify the full non-happy-state path**

```bash
cd ~/Projects/AICompleteChat
xcodebuild -project AICompleteChat.xcodeproj -scheme AICompleteChat -destination 'platform=macOS' -configuration Debug build
```

Launch the app fresh (delete `~/Library/Caches` MLX model cache first, or use a clean simulator/account, to genuinely see the download-progress state — do not skip this because the happy path already looks fine): confirm the New Screen shows downloading progress, then transitions to ready and starter prompts once the model finishes loading.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/AICompleteChat
git add AICompleteChat/Engine/AppEnvironment.swift AICompleteChat/ContentView.swift
cd ~/xCodeProjects/NerdSnipe-Inc-Packages/AiPersona
git add -A  # only if Step 2 required adding deleteAll()
git commit -m "feat: real model-load-state, memory clear/export wiring in ContentView"  # run in AICompleteChat repo
```

(If Step 2 required modifying AiPersona, commit that separately in the AiPersona repo with its own message, e.g. `feat: add MemoryGraphStore.deleteAll() for host-app memory reset`.)

---

## Task 14: Mic + Accessibility permission checks

**Files:**
- Modify: `~/Projects/AICompleteChat/AICompleteChat/Engine/AppEnvironment.swift`
- Modify: `~/Projects/AICompleteChat/AICompleteChat/ContentView.swift`
- Modify: `~/Projects/AICompleteChat/AICompleteChat/Info.plist` (or target's Info settings in Xcode)

**Interfaces:**
- Consumes: `AVCaptureDevice.authorizationStatus(for: .audio)` (AVFoundation), `AXIsProcessTrusted()` (ApplicationServices) — both are the exact APIs Alric's own voice permission handling already uses; read `alric/Features/Voice/Settings/AudioDevicesSettingsView.swift` and wherever Alric checks Accessibility trust (grep `AXIsProcessTrusted` in the alric repo) before writing this, to match the proven pattern rather than reinvent it.
- Produces: `AppEnvironment.micPermissionGranted: Bool`, `AppEnvironment.accessibilityPermissionGranted: Bool`, both consumed by `ContentView`'s `DFAIChatNewScreen` call site (replacing Task 12's implicit `true`/`true` that was never actually passed — this task adds the parameters for the first time, since Task 10's `DFAIChatNewScreen.Configuration` extension made them required-with-no-default only for the permission-banner-visibility purpose, not optional).

- [ ] **Step 1: Read Alric's existing permission-check pattern**

```bash
grep -rn "AXIsProcessTrusted\|AVCaptureDevice.authorizationStatus" ~/xCodeProjects/Alric-Platform/alric-compat-ios26/alric --include="*.swift"
```

- [ ] **Step 2: Add permission-status properties to AppEnvironment**

```swift
// AppEnvironment.swift — add
import AVFoundation
import ApplicationServices

var micPermissionGranted: Bool {
    AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
}

var accessibilityPermissionGranted: Bool {
    AXIsProcessTrusted()
}

func requestMicPermission() async {
    _ = await AVCaptureDevice.requestAccess(for: .audio)
}

func openSystemSettingsForPermissions() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
        NSWorkspace.shared.open(url)
    }
}
```

- [ ] **Step 3: Add the Info.plist usage-description key**

In the target's Info settings (Xcode → target → Info tab), add:
- Key: `Privacy - Microphone Usage Description`
- Value: `AICompleteChat uses your microphone for voice dictation and voice commands.`

- [ ] **Step 4: Wire into ContentView's DFAIChatNewScreen call site**

Update the `DFAIChatNewScreen.Configuration` construction (wherever `DFAIChatRootView`'s `detail` closure builds it, per Task 7 Step 2) to pass:

```swift
micPermissionGranted: appEnvironment.micPermissionGranted,
accessibilityPermissionGranted: appEnvironment.accessibilityPermissionGranted,
onOpenSystemSettings: { appEnvironment.openSystemSettingsForPermissions() }
```

- [ ] **Step 5: Build and manually verify**

```bash
cd ~/Projects/AICompleteChat
xcodebuild -project AICompleteChat.xcodeproj -scheme AICompleteChat -destination 'platform=macOS' -configuration Debug build
```

Launch on a fresh permission state (or manually revoke mic/Accessibility for the app in System Settings) and confirm the permission banners from Task 10 appear and "Open Settings" navigates correctly.

- [ ] **Step 6: Commit**

```bash
cd ~/Projects/AICompleteChat
git add AICompleteChat/Engine/AppEnvironment.swift AICompleteChat/ContentView.swift
git commit -m "feat: mic + Accessibility permission checks wired to New Screen banners"
```

---

## Task 15: Final manual smoke test + version bump

**Files:**
- Modify: `~/Projects/DesignFoundationPro/Package.swift` (version comment/tag prep — actual `git tag` is the user's call, not scripted here)
- No source changes beyond what Tasks 1–14 already produced.

**Interfaces:** none — this task is verification only.

- [ ] **Step 1: Full DesignFoundationPro test suite**

```bash
cd ~/Projects/DesignFoundationPro
swift test 2>&1 | tail -20
```

Expected: all tests pass.

- [ ] **Step 2: Full AICompleteChat build + test**

```bash
cd ~/Projects/AICompleteChat
xcodebuild -project AICompleteChat.xcodeproj -scheme AICompleteChat -destination 'platform=macOS' -configuration Debug build
xcodebuild test -project AICompleteChat.xcodeproj -scheme AICompleteChat -destination 'platform=macOS' 2>&1 | tail -40
```

Expected: `** BUILD SUCCEEDED **`, all tests pass.

- [ ] **Step 3: Manual smoke-test checklist (perform every item, do not skip any)**

- [ ] Launch app fresh — New Screen shows model-download progress, then transitions to ready
- [ ] Type a message, send — response streams token-by-token in the thread
- [ ] Say "Hey [assistant name], summarize this conversation" via the hotkey — voice command routes to `coordinator.send`, response appears
- [ ] Say "remember that I prefer dark mode" — confirm a fact appears in the Memory Inspector panel within a few seconds (background ingestion)
- [ ] Start a new conversation referencing "what did I say I prefer" — confirm the memory fact surfaces in the response
- [ ] Open Settings — model info, voice hotkeys, and memory sections all render with real data
- [ ] Clear memory from Settings — Memory Inspector panel returns to the empty state
- [ ] Revoke mic permission in System Settings, relaunch — New Screen shows the mic permission banner
- [ ] Revoke Accessibility permission, relaunch — New Screen shows the Accessibility permission banner

- [ ] **Step 4: Note the DesignFoundationPro version bump for the maintainer to tag**

This plan intentionally does not run `git tag 2.0.0` — confirm with the repo owner before tagging a released version. Leave `~/Projects/DesignFoundationPro/CHANGELOG.md`'s `## [2.0.0] — Unreleased` entry (added in Task 2) as the marker that a version bump is pending.

- [ ] **Step 5: Final status report**

```bash
cd ~/Projects/AICompleteChat && git log --oneline
cd ~/Projects/DesignFoundationPro && git log --oneline -20
cd ~/xCodeProjects/NerdSnipe-Inc-Packages/AiPersona && git log --oneline -5
```

Confirm every commit from Tasks 1–14 is present in the correct repo, and that no repo has a remote configured beyond what already existed before this plan (per Global Constraints — `AICompleteChat` and `AiVoiceKit` stay local-only; `DesignFoundationPro`/`AiPersona`'s existing `origin` remotes are untouched, and nothing was pushed).
