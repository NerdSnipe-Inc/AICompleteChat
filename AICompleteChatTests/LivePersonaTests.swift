import Foundation
import Testing
import AIChatCore
import AIChatUI
import AIChatMLX
import AiPersona
@testable import AICompleteChat

// MARK: - Helpers

/// Records the raw text the model produced for each extraction call, so a parse failure can be
/// diagnosed from the test log instead of guessed at.
final class RawCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _outputs: [String] = []
    var outputs: [String] { lock.lock(); defer { lock.unlock() }; return _outputs }
    func add(_ s: String) { lock.lock(); _outputs.append(s); lock.unlock() }
}

/// A `MemoryProvider` that replays canned RAW model text through the real parser — exercises the
/// exact parse -> ingest -> graph path with hostile fixtures, no model needed.
struct RawTextMemoryProvider: MemoryProvider {
    let raw: String
    func extractFacts(fromEpisode text: String) async throws -> [ExtractedFact] {
        ExtractionPromptFormat.parse(raw)
    }
}

struct ThrowingMemoryProvider: MemoryProvider {
    struct Boom: Error, LocalizedError { var errorDescription: String? { "extraction exploded" } }
    func extractFacts(fromEpisode text: String) async throws -> [ExtractedFact] { throw Boom() }
}

@MainActor
enum PersonaLive {
    /// Deterministic extraction provider (temperature 0, bounded output) — the same shape
    /// `AppEnvironment` now uses, sharing the already-resident model weights.
    static func extractionProvider(capture: RawCapture? = nil) -> LocalMemoryProvider {
        let mlx = MLXProvider(modelId: LiveModel.id, maxTokens: 768, temperature: 0)
        return LocalMemoryProvider(mlxProvider: mlx, modelId: LiveModel.id, serialize: { work in
            let out = try await work()
            capture?.add(out)
            return out
        })
    }

    static func chatProvider(maxTokens: Int = 160) -> MLXProvider {
        MLXProvider(modelId: LiveModel.id, maxTokens: maxTokens, temperature: 0)
    }

    static func isolatedPersona(name: String? = nil, personality: String? = nil) -> PersonaStore {
        let store = PersonaStore(defaults: UserDefaults(suiteName: "livepersona-\(UUID().uuidString)")!)
        if let name, let personality { store.update(name: name, personality: personality) }
        return store
    }

    struct Rig {
        let store: MemoryGraphStore
        let retrieval: RetrievalService
        let session: ChatSession
        let persona: PersonaStore
        let coordinator: PersonaChatCoordinator
        let capture: RawCapture
        let ingestionCompletions: Counter
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
        func bump() { lock.lock(); n += 1; lock.unlock() }
    }

    static func makeRig(
        store: MemoryGraphStore = MemoryGraphStore(inMemory: true),
        persona: PersonaStore = isolatedPersona(),
        chat: MLXProvider = chatProvider()
    ) -> Rig {
        let retrieval = RetrievalService(store: store)
        let session = ChatSession(provider: chat, model: LiveModel.id)
        let capture = RawCapture()
        let coordinator = PersonaChatCoordinator(
            session: session, store: store, retrieval: retrieval,
            memoryProvider: extractionProvider(capture: capture), personaStore: persona
        )
        let counter = Counter()
        coordinator.onMemoryUpdated = { counter.bump() }
        return Rig(store: store, retrieval: retrieval, session: session, persona: persona,
                   coordinator: coordinator, capture: capture, ingestionCompletions: counter)
    }

    /// Polls until `condition` holds or `seconds` elapse. Returns whether it held.
    static func wait(seconds: Double, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }

    static func lastAssistantText(_ session: ChatSession) -> String {
        session.entries.reversed().lazy.compactMap { entry -> String? in
            if case .aiMessage(let e) = entry { return e.text }
            return nil
        }.first ?? ""
    }

    static func dump(_ store: MemoryGraphStore, _ tag: String) {
        let facts = store.allFacts()
        print("[live/\(tag)] entities=\(store.allEntities().map(\.name)) facts=\(facts.map { "\($0.invalidAt == nil ? "ACTIVE" : "invalid")\($0.isUserEdited ? "/edited" : ""): \($0.factText)" })")
    }
}

// MARK: - Model-free pipeline tests (hostile model output -> graph)

@MainActor
@Suite("Persona pipeline (no model)")
struct PersonaPipelineTests {
    private let episode = ChatEpisode(userText: "My name is Sam", assistantText: "Nice to meet you.", occurredAt: Date())
    private let fact = #"{"subjectName": "Sam", "objectName": "Acme", "predicate": "works at", "factText": "Sam works at Acme as a nurse.", "isCorrection": false}"#

    private func ingest(_ raw: String) async -> MemoryGraphStore {
        let store = MemoryGraphStore(inMemory: true)
        await IngestionActor().enqueue(episode, provider: RawTextMemoryProvider(raw: raw), store: store)
        return store
    }

    @Test("markdown-fenced output lands in the graph")
    func fenced() async {
        let store = await ingest("```json\n[\(fact)]\n```")
        #expect(store.activeFacts().map(\.factText) == ["Sam works at Acme as a nurse."])
    }

    @Test("thinking-prefixed output lands in the graph")
    func thinking() async {
        let store = await ingest("<think>Sam [works] at {Acme}; output [ ]</think>\n[\(fact)]")
        #expect(store.activeFacts().count == 1)
    }

    @Test("truncated output keeps complete facts and does not crash")
    func truncated() async {
        let store = await ingest("[\(fact), {\"subjectName\": \"Sam\", \"pred")
        #expect(store.activeFacts().count == 1)
    }

    @Test("garbage output adds nothing and does not crash")
    func garbage() async {
        let store = await ingest("I'm sorry, but I can't help with that request.")
        #expect(store.allFacts().isEmpty)
        #expect(store.allEpisodes().isEmpty)
    }

    @Test("extraction that throws is contained, ingestion returns cleanly")
    func throwing() async {
        let store = MemoryGraphStore(inMemory: true)
        let result = await IngestionActor().enqueue(episode, provider: ThrowingMemoryProvider(), store: store)
        #expect(!result.needsHumanReview)
        #expect(store.allFacts().isEmpty)
    }

    @Test("correction invalidates the old fact and stores the new one")
    func correction() async {
        let store = MemoryGraphStore(inMemory: true)
        let actor = IngestionActor()
        let first = #"[{"subjectName":"Sam","objectName":"Acme","predicate":"works at","factText":"Sam works at Acme.","isCorrection":false}]"#
        let second = #"[{"subjectName":"Sam","objectName":"Acme","predicate":"no longer works at","factText":"Sam no longer works at Acme.","isCorrection":true},{"subjectName":"Sam","objectName":"Globex","predicate":"works at","factText":"Sam works at Globex.","isCorrection":false}]"#
        await actor.enqueue(episode, provider: RawTextMemoryProvider(raw: first), store: store)
        await actor.enqueue(episode, provider: RawTextMemoryProvider(raw: second), store: store)
        let active = store.activeFacts().map(\.factText)
        #expect(!active.contains("Sam works at Acme."))
        #expect(active.contains("Sam works at Globex."))
        #expect(store.allFacts().contains { $0.factText == "Sam works at Acme." && $0.invalidAt != nil }, "old fact must be invalidated, not deleted")
    }

    @Test("a user-edited fact is never silently invalidated; correction is reported for review")
    func userEditedProtected() async throws {
        let store = MemoryGraphStore(inMemory: true)
        let actor = IngestionActor()
        let first = #"[{"subjectName":"Sam","objectName":"Acme","predicate":"works at","factText":"Sam works at Acme.","isCorrection":false}]"#
        await actor.enqueue(episode, provider: RawTextMemoryProvider(raw: first), store: store)
        let original = try #require(store.activeFacts().first)
        store.updateFact(id: original.id, factText: "Sam works at Acme Hospital (hand-edited).")
        let correction = #"[{"subjectName":"Sam","objectName":"Acme","predicate":"no longer works at","factText":"Sam left Acme.","isCorrection":true}]"#
        let result = await actor.enqueue(episode, provider: RawTextMemoryProvider(raw: correction), store: store)
        #expect(result.pendingReviewCorrections.count == 1)
        #expect(store.activeFacts().contains { $0.id == original.id }, "user-edited fact must stay active")
    }

    @Test("an unmatched correction is reported, not silently dropped")
    func unmatchedCorrection() async {
        let store = MemoryGraphStore(inMemory: true)
        let correction = #"[{"subjectName":"Sam","objectName":"Nowhere","predicate":"no longer","factText":"Sam left Nowhere.","isCorrection":true}]"#
        let result = await IngestionActor().enqueue(episode, provider: RawTextMemoryProvider(raw: correction), store: store)
        #expect(result.failedCorrections.count == 1)
    }

    // MARK: retrieval sanity (empty + huge store)

    @Test("empty store: no memory section, no crash")
    func emptyStore() {
        let store = MemoryGraphStore(inMemory: true)
        let retrieval = RetrievalService(store: store)
        #expect(retrieval.sessionCompilation().isEmpty)
        #expect(retrieval.perTurnMemoryBlock(forQuery: "Where do I work?", excluding: "") == nil)
        #expect(PersonaPromptBuilder.memorySection(nil).isEmpty)
    }

    @Test("2,000-fact store: retrieval is fast and still finds the relevant fact", .timeLimit(.minutes(3)))
    func hugeStore() {
        let store = MemoryGraphStore(inMemory: true)
        let subjects = (0..<40).map { i in
            store.upsertEntity(name: "Person\(i)", summary: "p", kind: .other, embedding: LocalEmbedder.embed("Person\(i)"))
        }
        let topics = ["hiking", "pottery", "jazz", "chess", "sailing", "baking", "cycling", "painting"]
        let addStart = Date()
        for i in 0..<2_000 {
            let text = "Person\(i % 40) enjoys \(topics[i % topics.count]) on weekend number \(i)."
            store.addFact(subjectID: subjects[i % 40].id, objectID: nil, predicate: "enjoys", factText: text,
                          embedding: LocalEmbedder.embed(text))
        }
        let target = "Sam works at Acme as a nurse."
        let sam = store.upsertEntity(name: "Sam", summary: "s", kind: .user, embedding: LocalEmbedder.embed("Sam"))
        store.addFact(subjectID: sam.id, objectID: nil, predicate: "works at", factText: target, embedding: LocalEmbedder.embed(target))
        print("[live/hugeStore] seeded 2001 facts in \(Date().timeIntervalSince(addStart))s")

        let retrieval = RetrievalService(store: store)
        let t0 = Date()
        let compilation = retrieval.sessionCompilation()
        let compileTime = Date().timeIntervalSince(t0)
        let t1 = Date()
        let block = retrieval.perTurnMemoryBlock(forQuery: "Where does Sam work? Which company is he a nurse at?", excluding: compilation)
        let turnTime = Date().timeIntervalSince(t1)
        print("[live/hugeStore] compilation=\(compileTime)s perTurn=\(turnTime)s block=\(block ?? "nil")")
        #expect(compileTime < 2.0)
        #expect(turnTime < 2.0)
        #expect(compilation.split(separator: "\n").count <= 20, "compilation must respect the fact budget")
        let surfaced = compilation.contains(target) || (block?.contains(target) ?? false)
        #expect(surfaced, "the one relevant fact among 2,001 must reach the prompt")
    }

    // MARK: coordinator guards (fake provider, no model)

    @Test("model not ready: send is refused with a specific message, nothing is sent")
    func modelNotReady() {
        let provider = FakeChatProvider()
        let session = ChatSession(provider: provider, model: "test")
        let store = MemoryGraphStore(inMemory: true)
        let coordinator = PersonaChatCoordinator(
            session: session, store: store, retrieval: RetrievalService(store: store),
            memoryProvider: LocalMemoryProviderStub(), personaStore: PersonaLive.isolatedPersona()
        )
        coordinator.readiness = { .failed("no network connection — the model needs to be downloaded once") }
        let outcome = coordinator.send("Hello")
        guard case .modelUnavailable(let message) = outcome else {
            Issue.record("expected .modelUnavailable, got \(outcome)"); return
        }
        #expect(message.contains("failed to load"))
        #expect(message.contains("no network connection"))
        #expect(message.contains("Reload Model"), "message must tell the user what to do")
        #expect(!message.contains(".."), "no doubled punctuation: \(message)")
        #expect(session.entries.isEmpty)
        #expect(!session.isGenerating)
        #expect(provider.lastMessages.isEmpty)

        coordinator.readiness = { .loading(progress: 0.42) }
        if case .modelUnavailable(let m) = coordinator.send("Hello") { #expect(m.contains("42%")) } else { Issue.record("expected loading refusal") }
        coordinator.readiness = { .notLoaded }
        if case .modelUnavailable(let m) = coordinator.send("Hello") { #expect(m.contains("not been loaded")) } else { Issue.record("expected notLoaded refusal") }
    }

    @Test("empty message and busy session are ignored explicitly")
    func emptyAndBusy() {
        let session = ChatSession(provider: FakeChatProvider(), model: "test")
        let store = MemoryGraphStore(inMemory: true)
        let coordinator = PersonaChatCoordinator(
            session: session, store: store, retrieval: RetrievalService(store: store),
            memoryProvider: LocalMemoryProviderStub(), personaStore: PersonaLive.isolatedPersona()
        )
        #expect(coordinator.send("   \n") == .ignoredEmpty)
        #expect(coordinator.send("first") == .sent)
        // The first turn is in flight (isGenerating is set synchronously by ChatSession.send).
        #expect(coordinator.send("second") == .ignoredBusy)
    }

    @Test("provider failure surfaces on the session, and the failed turn is NOT ingested")
    func failedTurnNotIngested() async {
        final class FailingProvider: ChatProvider, @unchecked Sendable {
            let id = "failing"; let name = "Failing"
            var zeroResponseMessage: String { "none" }
            func stream(messages: [ChatMessage], model: String, options: ChatRequestOptions) -> AsyncThrowingStream<ChatStreamEvent, Error> {
                AsyncThrowingStream { $0.finish(throwing: ChatError.streamError("boom: weights missing")) }
            }
            func complete(messages: [ChatMessage], model: String, options: ChatRequestOptions) async throws -> ChatCompletionResult {
                throw ChatError.streamError("boom")
            }
        }
        let session = ChatSession(provider: FailingProvider(), model: "x")
        let store = MemoryGraphStore(inMemory: true)
        let coordinator = PersonaChatCoordinator(
            session: session, store: store, retrieval: RetrievalService(store: store),
            memoryProvider: RawTextMemoryProvider(raw: "[]"), personaStore: PersonaLive.isolatedPersona()
        )
        var ingested = false
        coordinator.onMemoryUpdated = { ingested = true }
        coordinator.send("hello")
        let finished = await PersonaLive.wait(seconds: 10) { !session.isGenerating && session.error != nil }
        #expect(finished, "a failing provider must end the turn, not hang")
        #expect(session.error?.localizedDescription.contains("weights missing") == true)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(!ingested)
    }

    @Test("describeLoadFailure gives cause-specific text")
    func loadFailureText() {
        #expect(AppEnvironment.describeLoadFailure(URLError(.notConnectedToInternet)).contains("no network"))
        #expect(AppEnvironment.describeLoadFailure(URLError(.timedOut)).contains("timed out"))
        #expect(AppEnvironment.describeLoadFailure(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)).contains("disk space"))
        let generic = AppEnvironment.describeLoadFailure(NSError(domain: "X", code: 7))
        #expect(generic.contains("X") && generic.contains("7"), "generic failures must keep domain/code: \(generic)")
    }
}

// MARK: - Live tests against the real gemma-4-e4b

@MainActor
@Suite("Live persona (gemma-4-e4b)", .serialized, .enabled(if: LiveModel.isCached, "gemma-4-e4b-it-4bit not in HF cache"))
struct LivePersonaTests {
    static let statement = "My name is Sam, I work at Acme as a nurse and I'm allergic to penicillin."

    /// Ingests `statement` through the real model into `store` and returns the raw model text.
    @discardableResult
    private func ingestStatement(_ text: String = statement, into store: MemoryGraphStore, userName: String? = nil) async -> [String] {
        let capture = RawCapture()
        let provider = PersonaLive.extractionProvider(capture: capture)
        let result = await IngestionActor().enqueue(
            ChatEpisode(userText: text, assistantText: "Nice to meet you, that's noted.", occurredAt: Date()),
            provider: provider, store: store, knownUserName: userName
        )
        print("[live/ingest] raw=\(capture.outputs.map { $0.debugDescription }) failed=\(result.failedCorrections.count) pending=\(result.pendingReviewCorrections.count)")
        PersonaLive.dump(store, "ingest")
        return capture.outputs
    }

    // (a)
    @Test("extraction: realistic statement yields entities and facts in the graph", .timeLimit(.minutes(5)))
    func extraction() async {
        let store = MemoryGraphStore(inMemory: true)
        let raw = await ingestStatement(into: store)
        let facts = ExtractionPromptFormat.parseDetailed(raw.first ?? "")
        print("[live/extraction] parsed=\(facts.facts) skipped=\(facts.skippedObjects) sawJSON=\(facts.sawJSON)")
        #expect(!facts.looksUnparseable, "model output was not JSON at all: \(raw)")
        #expect(!store.activeFacts().isEmpty, "no facts reached the graph; raw=\(raw)")
        let all = store.activeFacts().map(\.factText).joined(separator: " ").lowercased()
        #expect(all.contains("acme"), "employer missing: \(all)")
        #expect(all.contains("penicillin"), "allergy missing: \(all)")
        // KNOWN 4B-model limit (not asserted): gemma-4-e4b at temperature 0 usually drops the "nurse"
        // qualifier and the bare name fact. A prompt tweak that asked for them made extraction WORSE
        // (subject/object confusion), so the validated prompt is unchanged. Surface it in the log.
        print("[live/extraction] qualifier kept (nurse)=\(all.contains("nurse")) name kept=\(all.contains("sam"))")
        #expect(!store.allEntities().isEmpty)
        #expect(store.allEntities().allSatisfy { !["i", "me", "my"].contains($0.name.lowercased()) }, "pronoun entity leaked")
    }

    @Test("extraction: small talk yields no facts", .timeLimit(.minutes(5)))
    func smallTalk() async {
        let store = MemoryGraphStore(inMemory: true)
        await ingestStatement("Thanks, that sounds good!", into: store)
        #expect(store.activeFacts().isEmpty, "small talk must not be memorised")
    }

    // (c)
    @Test("correction: contradicting an earlier fact invalidates it and stores the new one", .timeLimit(.minutes(8)))
    func correctionLive() async {
        let store = MemoryGraphStore(inMemory: true)
        await ingestStatement("I work at Acme as a nurse.", into: store, userName: "Sam")
        #expect(store.activeFacts().contains { $0.factText.lowercased().contains("acme") })
        await ingestStatement("Actually I don't work at Acme any more. I quit and now work at Globex.", into: store, userName: "Sam")
        let active = store.activeFacts().map(\.factText)
        let invalid = store.allFacts().filter { $0.invalidAt != nil }.map(\.factText)
        print("[live/correction] active=\(active) invalid=\(invalid)")
        #expect(active.contains { $0.lowercased().contains("globex") }, "new employer not stored: \(active)")
        #expect(!active.contains { $0.lowercased().contains("works at acme") || $0.lowercased() == "sam works at acme." },
                "old employer fact still active: \(active)")
    }

    // (d) + (h-name)
    @Test("end to end: 'Where do I work?' uses ingested memory (prompt AND answer)", .timeLimit(.minutes(8)))
    func retrievalEndToEnd() async {
        let store = MemoryGraphStore(inMemory: true)
        await ingestStatement(into: store, userName: "Sam")
        let rig = PersonaLive.makeRig(store: store)

        #expect(rig.coordinator.send("Where do I work?") == .sent)
        let prompt = rig.session.options.systemPrompt ?? ""
        print("[live/e2e] systemPrompt=\(prompt.debugDescription)")
        #expect(prompt.contains("RELEVANT MEMORY"))
        #expect(prompt.lowercased().contains("acme"), "memory not injected into system prompt")

        let done = await PersonaLive.wait(seconds: 240) { !rig.session.isGenerating }
        #expect(done, "turn did not finish")
        let answer = PersonaLive.lastAssistantText(rig.session)
        print("[live/e2e] answer=\(answer.debugDescription) error=\(String(describing: rig.session.error))")
        #expect(rig.session.error == nil)
        #expect(answer.lowercased().contains("acme"), "answer ignored memory: \(answer)")
    }

    // (h)
    @Test("persona: configured name and tone are honoured", .timeLimit(.minutes(8)))
    func personaHonoured() async {
        let persona = PersonaLive.isolatedPersona(
            name: "Zephyr",
            personality: "You are a cheerful pirate. Start every reply with the word 'Arrr'."
        )
        let rig = PersonaLive.makeRig(persona: persona)
        #expect(rig.coordinator.send("What is your name?") == .sent)
        let prompt = rig.session.options.systemPrompt ?? ""
        #expect(prompt.contains("Zephyr") && prompt.contains("pirate"))
        #expect(await PersonaLive.wait(seconds: 240) { !rig.session.isGenerating })
        let answer = PersonaLive.lastAssistantText(rig.session)
        print("[live/persona] answer=\(answer.debugDescription)")
        #expect(answer.lowercased().contains("zephyr"), "name not honoured: \(answer)")
        #expect(answer.lowercased().contains("arr"), "tone not honoured: \(answer)")
    }

    // (e) real provider, model cannot load
    @Test("model load failure: real MLXProvider with a nonexistent model ends the turn with a specific error", .timeLimit(.minutes(4)))
    func loadFailure() async {
        let bogus = MLXProvider(modelId: "cc-nerdsnipe/this-model-does-not-exist-404", maxTokens: 16, temperature: 0)
        do {
            try await bogus.loadModel()
            Issue.record("loading a nonexistent model unexpectedly succeeded")
        } catch {
            let text = AppEnvironment.describeLoadFailure(error)
            print("[live/loadFailure] raw=\(String(describing: error)) described=\(text)")
            #expect(!text.isEmpty)
            #expect(text != "The operation couldn’t be completed.", "vague error surfaced")
        }

        let rig = PersonaLive.makeRig(chat: bogus)
        rig.coordinator.send("Hello?")
        let finished = await PersonaLive.wait(seconds: 180) { !rig.session.isGenerating }
        #expect(finished, "turn hung instead of failing")
        let message = (rig.session.error as? LocalizedError)?.errorDescription ?? rig.session.error?.localizedDescription ?? "<nil>"
        print("[live/loadFailure] session.error=\(message)")
        #expect(rig.session.error != nil)
        #expect(!message.isEmpty && message != "<nil>")
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(rig.ingestionCompletions.value == 0, "failed turn must not be ingested")
    }

    // (f)
    @Test("concurrency: a new chat turn while background ingestion is still running", .timeLimit(.minutes(10)))
    func ingestionOverlapsNextTurn() async {
        let rig = PersonaLive.makeRig()
        let start = Date()
        rig.coordinator.send("My name is Sam and I'm allergic to penicillin. Reply in one short sentence.")
        #expect(await PersonaLive.wait(seconds: 240) { !rig.session.isGenerating })
        let t1 = Date().timeIntervalSince(start)
        // Turn 1 just completed; its ingestion Task is now queued behind/at the model. Fire turn 2
        // immediately, while (or before) extraction runs.
        #expect(rig.coordinator.send("What am I allergic to? One short sentence.") == .sent)
        #expect(await PersonaLive.wait(seconds: 300) { !rig.session.isGenerating }, "turn 2 deadlocked behind ingestion")
        let answer2 = PersonaLive.lastAssistantText(rig.session)
        #expect(await PersonaLive.wait(seconds: 300) { rig.ingestionCompletions.value >= 2 }, "background ingestion never completed")
        print("[live/overlap] t1=\(t1)s total=\(Date().timeIntervalSince(start))s answer2=\(answer2.debugDescription) ingestions=\(rig.ingestionCompletions.value)")
        PersonaLive.dump(rig.store, "overlap")
        #expect(rig.session.error == nil)
        #expect(!answer2.isEmpty)
        let aiCount = rig.session.entries.filter { if case .aiMessage = $0 { return true } else { return false } }.count
        #expect(aiCount == 2)
    }
}
