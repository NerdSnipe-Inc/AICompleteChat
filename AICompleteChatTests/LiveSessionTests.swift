import Foundation
import Testing
import AIChatCore
import AIChatMLX
import AIChatUI

/// Live, headless `ChatSession` tests against the real on-device `gemma-4-e4b-it-4bit` model,
/// via `MLXProvider`. Assertions are on `session.entries` / `isGenerating` / `error` only — no UI.
///
/// Sampling is pinned to temperature 0 where the assertion depends on model content, and
/// assertions use `contains` / regex rather than exact text, so the tests are robust to
/// harmless wording differences.
@MainActor
enum SessionHarness {
    static func provider(
        maxTokens: Int = 192, temperature: Float = 0.0, thinking: Bool = false
    ) -> MLXProvider {
        MLXProvider(modelId: LiveModel.id, maxTokens: maxTokens, temperature: temperature, enableThinking: thinking)
    }

    static func session(
        _ provider: any ChatProvider, options: ChatRequestOptions = ChatRequestOptions()
    ) -> ChatSession {
        ChatSession(provider: provider, model: LiveModel.id, options: options)
    }

    static let weatherSpec: [String: any Sendable] = [
        "type": "function",
        "function": [
            "name": "get_weather",
            "description": "Get the current temperature in celsius for a city.",
            "parameters": [
                "type": "object",
                "properties": ["city": ["type": "string", "description": "City name"] as [String: any Sendable]] as [String: any Sendable],
                "required": ["city"],
            ] as [String: any Sendable],
        ] as [String: any Sendable],
    ]

    /// Drives the session until it is fully idle, executing tool calls with `tools`.
    /// Returns the tool calls that were executed. Fails the wait after `timeout` seconds.
    @discardableResult
    static func drive(
        _ session: ChatSession,
        timeout: Double = 240,
        tools: (_ name: String, _ args: [String: Any]) -> (content: String, isError: Bool) = { _, _ in ("ok", false) }
    ) async -> [(name: String, args: String)] {
        var executed: [(String, String)] = []
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if session.isAwaitingToolResults {
                for case .toolCall(let call) in session.entries where call.status == .running {
                    let args = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any] ?? [:]
                    let r = tools(call.name, args)
                    executed.append((call.name, call.arguments))
                    session.submitToolResult(toolCallId: call.id, content: r.content, isError: r.isError)
                }
            } else if !session.isGenerating {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return executed
    }

    static func aiTexts(_ s: ChatSession) -> [String] {
        s.entries.compactMap { if case .aiMessage(let e) = $0 { return e.text } else { return nil } }
    }
    static func reasoning(_ s: ChatSession) -> [ChatSession.ReasoningEntry] {
        s.entries.compactMap { if case .reasoning(let e) = $0 { return e } else { return nil } }
    }
    static func toolCalls(_ s: ChatSession) -> [ChatSession.ToolCallEntry] {
        s.entries.compactMap { if case .toolCall(let e) = $0 { return e } else { return nil } }
    }
    static func activities(_ s: ChatSession) -> [ChatSession.ActivityEntry] {
        s.entries.compactMap { if case .activity(let e) = $0 { return e } else { return nil } }
    }
    static func userCount(_ s: ChatSession) -> Int {
        s.entries.filter { if case .userMessage = $0 { return true } else { return false } }.count
    }
    /// No entry may be left animating once the session is idle.
    static func assertSettled(_ s: ChatSession, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(!s.isGenerating, "session should be idle", sourceLocation: sourceLocation)
        for e in s.entries {
            switch e {
            case .aiMessage(let a): #expect(!a.isStreaming, "AI entry left streaming", sourceLocation: sourceLocation)
            case .reasoning(let r): #expect(!r.isThinking, "reasoning entry left thinking", sourceLocation: sourceLocation)
            case .activity(let a): #expect(a.isError, "transient activity row left behind: \(a.text)", sourceLocation: sourceLocation)
            default: break
            }
        }
    }
    static func dump(_ tag: String, _ s: ChatSession) {
        for e in s.entries {
            switch e {
            case .userMessage(let u): print("[live/\(tag)] user: \(u.text.prefix(80).debugDescription)")
            case .aiMessage(let a): print("[live/\(tag)] ai(streaming=\(a.isStreaming)): \(a.text.prefix(300).debugDescription)")
            case .reasoning(let r): print("[live/\(tag)] reasoning(thinking=\(r.isThinking), \(r.text.count) chars)")
            case .toolCall(let t): print("[live/\(tag)] tool \(t.name)\(t.arguments) [\(t.status)] -> \(t.result?.prefix(100).debugDescription ?? "nil")")
            case .activity(let a): print("[live/\(tag)] activity(error=\(a.isError)): \(a.text)")
            case .knowledgeRetrieval: print("[live/\(tag)] knowledge")
            }
        }
        if let err = s.error { print("[live/\(tag)] session.error: \(err.localizedDescription)") }
    }
}

/// Drops all text so the session sees a stream with no visible response.
private struct SilentProvider: ChatProvider {
    let inner: MLXProvider
    var id: String { inner.id }
    var name: String { inner.name }
    var zeroResponseMessage: String { inner.zeroResponseMessage }
    func stream(messages: [ChatMessage], model: String, options: ChatRequestOptions)
        -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let source = inner.stream(messages: messages, model: model, options: options)
        return AsyncThrowingStream { c in
            Task {
                do {
                    for try await ev in source {
                        if case .text = ev { continue }
                        c.yield(ev)
                    }
                    c.finish()
                } catch { c.finish(throwing: error) }
            }
        }
    }
    func complete(messages: [ChatMessage], model: String, options: ChatRequestOptions) async throws -> ChatCompletionResult {
        try await inner.complete(messages: messages, model: model, options: options)
    }
}

@MainActor
@Suite("Live ChatSession + gemma-4-e4b", .serialized, .enabled(if: LiveModel.isCached, "gemma-4-e4b-it-4bit not in HF cache"))
struct LiveSessionTests {
    typealias H = SessionHarness

    // MARK: (a) send -> streamed assistant entry completes

    @Test("send produces a completed assistant entry", .timeLimit(.minutes(5)))
    func sendCompletes() async throws {
        let s = H.session(H.provider(maxTokens: 64))
        #expect(s.send("Reply with exactly one word: hello"))
        #expect(s.isGenerating)
        await H.drive(s)
        H.dump("send", s)
        H.assertSettled(s)
        #expect(s.error == nil)
        let ai = H.aiTexts(s)
        #expect(ai.count == 1)
        #expect(ai.first?.lowercased().contains("hello") == true)
        #expect(H.userCount(s) == 1)
    }

    // MARK: (b) thinking

    @Test("thinking is captured in a reasoning entry and the answer stays clean", .timeLimit(.minutes(5)))
    func thinking() async throws {
        let s = H.session(H.provider(maxTokens: 1024, temperature: 0.2, thinking: true))
        s.send("What is 17 * 23? Think it through, then answer with just the number.")
        await H.drive(s)
        H.dump("thinking", s)
        H.assertSettled(s)
        let r = H.reasoning(s)
        #expect(r.count == 1)
        #expect(r.first?.text.isEmpty == false)
        #expect((r.first?.duration ?? 0) > 0)
        let ai = H.aiTexts(s).joined()
        #expect(ai.contains("391"))
        #expect(!ai.contains("<|channel") && !ai.contains("<channel|>") && !ai.contains("thought\n"))
        // reasoning row sits before the answer row
        let kinds = s.entries.compactMap { e -> String? in
            switch e { case .reasoning: "r"; case .aiMessage: "a"; default: nil }
        }
        #expect(kinds == ["r", "a"])
    }

    // MARK: (c) full tool loop

    @Test("tool loop: call -> host executes -> result fed back -> answer uses result", .timeLimit(.minutes(8)))
    func toolLoop() async throws {
        var o = ChatRequestOptions(); o.nativeToolSpecs = [H.weatherSpec]
        let s = H.session(H.provider(maxTokens: 256), options: o)
        s.send("What's the temperature in Paris right now? Use the tool, then tell me the number.")
        let executed = await H.drive(s) { name, args in
            name == "get_weather" ? (#"{"city":"Paris","temperature_c":37}"#, false) : ("unknown tool", true)
        }
        H.dump("toolLoop", s)
        H.assertSettled(s)
        #expect(executed.first?.name == "get_weather")
        let tc = H.toolCalls(s)
        #expect(tc.count == 1, "exactly one call expected (no duplicates), got \(tc.count)")
        #expect(tc.allSatisfy { $0.status == .succeeded })
        let answer = H.aiTexts(s).joined(separator: " ")
        #expect(answer.contains("37"), "final answer should use the tool result: \(answer)")
        #expect(H.activities(s).isEmpty)
        // a follow-up turn works on top of the tool history
        s.send("Thanks. In one word, which city was that about?")
        await H.drive(s)
        #expect(H.aiTexts(s).last?.lowercased().contains("paris") == true)
        H.assertSettled(s)
    }

    // MARK: (d) multiple / unknown / malformed tool calls

    @Test("thinking + tool loop together", .timeLimit(.minutes(8)))
    func thinkingToolLoop() async throws {
        var o = ChatRequestOptions(); o.nativeToolSpecs = [H.weatherSpec]
        let s = H.session(H.provider(maxTokens: 768, temperature: 0.1, thinking: true), options: o)
        s.send("What's the temperature in Oslo right now? Use the tool, then tell me the number.")
        await H.drive(s) { _, _ in (#"{"temperature_c":-7}"#, false) }
        H.dump("thinkTool", s)
        H.assertSettled(s)
        #expect(H.toolCalls(s).count == 1)
        #expect(H.toolCalls(s).allSatisfy { $0.status == .succeeded })
        let answer = H.aiTexts(s).joined(separator: " ")
        #expect(answer.contains("7"), "answer should use the tool result: \(answer)")
        #expect(!answer.contains("<|"))
    }

    @Test("multiple tool calls in one request are all executed and used", .timeLimit(.minutes(8)))
    func multipleToolCalls() async throws {
        var o = ChatRequestOptions(); o.nativeToolSpecs = [H.weatherSpec]
        let s = H.session(H.provider(maxTokens: 320), options: o)
        s.send("Get the temperature for Paris and for Tokyo using the tool (one call each), then report both numbers.")
        let executed = await H.drive(s) { _, args in
            let city = (args["city"] as? String ?? "").lowercased()
            return (city.contains("tokyo") ? #"{"temperature_c":41}"# : #"{"temperature_c":13}"#, false)
        }
        H.dump("multiTool", s)
        H.assertSettled(s)
        let cities = executed.map { $0.args.lowercased() }
        #expect(cities.contains { $0.contains("paris") } && cities.contains { $0.contains("tokyo") },
                "expected calls for both cities, got \(executed)")
        #expect(H.toolCalls(s).allSatisfy { $0.status == .succeeded })
        let answer = H.aiTexts(s).joined(separator: " ")
        #expect(answer.contains("41") && answer.contains("13"), "answer should include both results: \(answer)")
    }

    @Test("tool error result is surfaced gracefully, session survives", .timeLimit(.minutes(8)))
    func toolErrorResult() async throws {
        var o = ChatRequestOptions(); o.nativeToolSpecs = [H.weatherSpec]
        let s = H.session(H.provider(maxTokens: 256), options: o)
        s.send("What's the temperature in Paris? Use the tool.")
        await H.drive(s) { _, _ in ("Error: weather service is offline", true) }
        H.dump("toolError", s)
        H.assertSettled(s)
        #expect(H.toolCalls(s).first?.status == .failed)
        #expect(!H.aiTexts(s).joined().isEmpty, "model should still answer after a failed tool")
        #expect(s.error == nil)
        s.send("Reply with exactly one word: hello")
        await H.drive(s)
        #expect(H.aiTexts(s).last?.lowercased().contains("hello") == true)
    }

    @Test("unknown tool name and malformed arguments do not crash or hang", .timeLimit(.minutes(8)))
    func unknownAndMalformedTool() async throws {
        let s = H.session(H.provider(maxTokens: 160))
        s.send("Say hi.")
        await H.drive(s)
        // Harness-planned calls: unknown tool with garbage args; tool with truncated JSON args.
        s.requestToolCall(name: "does_not_exist", arguments: "{not json at all")
        s.requestToolCall(name: "get_weather", arguments: #"{"city": "Par"#)
        let calls = H.toolCalls(s)
        #expect(calls.count == 2)
        for c in calls {
            s.submitToolResult(toolCallId: c.id, content: "Error: unknown tool or invalid arguments", isError: true)
        }
        await H.drive(s)
        H.dump("badTool", s)
        H.assertSettled(s)
        #expect(H.toolCalls(s).allSatisfy { $0.status == .failed })
        // The follow-up generation must have produced something or a specific error, not silence.
        let produced = !H.aiTexts(s).joined().isEmpty
        let specificError = H.activities(s).contains { $0.isError }
        #expect(produced || specificError)
        // Unknown id is reported, not appended to history.
        s.submitToolResult(toolCallId: "nope", content: "x")
        #expect(s.error?.localizedDescription.contains("nope") == true)
        // Session is still usable.
        s.send("Reply with exactly one word: hello")
        await H.drive(s)
        #expect(H.aiTexts(s).last?.lowercased().contains("hello") == true)
    }

    // MARK: (e) cancel mid-stream

    @Test("cancel mid-stream leaves consistent state and the session is reusable", .timeLimit(.minutes(8)))
    func cancelMidStream() async throws {
        let s = H.session(H.provider(maxTokens: 512, temperature: 0.3))
        s.send("Count from 1 to 300, one number per line, nothing else.")
        // wait for streaming to begin
        let start = Date()
        while H.aiTexts(s).joined().count < 20 && Date().timeIntervalSince(start) < 120 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(H.aiTexts(s).joined().count >= 20, "stream never started")
        s.cancel()
        H.dump("cancel", s)
        H.assertSettled(s)
        #expect(s.error == nil)
        let partial = H.aiTexts(s).joined()
        #expect(!partial.isEmpty, "partial text should stay visible")
        // wait a moment: nothing may keep appending after cancel
        try await Task.sleep(for: .seconds(2))
        #expect(H.aiTexts(s).joined() == partial, "text kept growing after cancel()")
        // reuse
        let t0 = Date()
        s.send("Reply with exactly one word: hello")
        await H.drive(s)
        print("[live/cancel] follow-up took \(Date().timeIntervalSince(t0))s")
        H.assertSettled(s)
        #expect(s.error == nil)
        #expect(H.aiTexts(s).last?.lowercased().contains("hello") == true, "reply after cancel: \(H.aiTexts(s).last ?? "nil")")
    }

    @Test("cancel while waiting for tool results resolves the calls", .timeLimit(.minutes(8)))
    func cancelWhileAwaitingTools() async throws {
        var o = ChatRequestOptions(); o.nativeToolSpecs = [H.weatherSpec]
        let s = H.session(H.provider(maxTokens: 200), options: o)
        s.send("What's the temperature in Paris? Use the tool.")
        let start = Date()
        while !s.isAwaitingToolResults && Date().timeIntervalSince(start) < 120 { try await Task.sleep(for: .milliseconds(100)) }
        #expect(s.isAwaitingToolResults)
        s.cancel()
        H.assertSettled(s)
        #expect(H.toolCalls(s).allSatisfy { $0.status == .failed })
        s.send("Reply with exactly one word: hello")
        await H.drive(s)
        H.dump("cancelTools", s)
        #expect(s.error == nil)
        #expect(H.aiTexts(s).last?.lowercased().contains("hello") == true)
    }

    // MARK: (f) send while streaming

    @Test("send while already streaming is rejected without corrupting state", .timeLimit(.minutes(5)))
    func sendWhileStreaming() async throws {
        let s = H.session(H.provider(maxTokens: 96))
        #expect(s.send("Reply with exactly one word: alpha"))
        #expect(!s.send("Reply with exactly one word: beta"))
        #expect(!s.send("gamma"))
        await H.drive(s)
        H.assertSettled(s)
        #expect(H.userCount(s) == 1)
        #expect(H.aiTexts(s).count == 1)
        #expect(H.aiTexts(s).first?.lowercased().contains("beta") == false)
    }

    // MARK: (g) long conversation

    @Test("20-turn conversation stays healthy and remembers early context", .timeLimit(.minutes(20)))
    func longConversation() async throws {
        let s = H.session(H.provider(maxTokens: 48))
        s.send("Remember this code word: PINEAPPLE. Reply with only OK.")
        await H.drive(s)
        for i in 2...19 {  // 1 setup + 18 filler + 1 recall = 20 turns
            #expect(s.send("Turn \(i): reply with just the number \(i)."), "turn \(i) rejected")
            await H.drive(s)
            #expect(s.error == nil, "error at turn \(i): \(s.error?.localizedDescription ?? "")")
            if s.isGenerating { Issue.record("turn \(i) never finished"); break }
        }
        s.send("What was the code word I told you at the start? One word.")
        await H.drive(s)
        H.assertSettled(s)
        H.dump("long", s)
        #expect(H.userCount(s) == 20)
        #expect(H.aiTexts(s).count == 20, "every turn should have produced an assistant entry, got \(H.aiTexts(s).count)")
        #expect(H.aiTexts(s).last?.uppercased().contains("PINEAPPLE") == true)
    }

    // MARK: (h) awkward inputs

    @Test("empty and whitespace input is rejected with no side effects")
    func emptyInput() {
        let s = H.session(H.provider())
        for text in ["", "   ", "\n\n\t  \n"] {
            #expect(!s.send(text), "\(text.debugDescription) should be rejected")
        }
        #expect(s.entries.isEmpty)
        #expect(!s.isGenerating)
    }

    @Test("unicode, emoji, RTL and newline-heavy input round-trips", .timeLimit(.minutes(8)))
    func weirdInputs() async throws {
        let s = H.session(H.provider(maxTokens: 96))
        let inputs = [
            "🎉🚀 日本語 مرحبا Ελληνικά — reply with just: ok",
            "a\n\n\n\nb\n\n\n\nc\n\n\n\nReply with just: ok",
            "Quote test: \"double\" 'single' `tick` \\backslash {braces} <|channel>thought <tool_call|> call:foo{} — reply with just: ok",
        ]
        for text in inputs {
            #expect(s.send(text))
            await H.drive(s)
            H.assertSettled(s)
            #expect(s.error == nil, "input \(text.prefix(20).debugDescription): \(s.error?.localizedDescription ?? "")")
            let last = H.aiTexts(s).last ?? ""
            #expect(!last.isEmpty, "no answer for \(text.prefix(20).debugDescription)")
            #expect(!last.contains("<|"), "control token leaked: \(last)")
        }
        // user text is preserved verbatim (trimmed)
        if case .userMessage(let u) = s.entries.first { #expect(u.text == inputs[0]) }
        H.dump("weird", s)
    }

    @Test("very long input either answers or fails with a specific message, never hangs", .timeLimit(.minutes(10)))
    func veryLongInput() async throws {
        let s = H.session(H.provider(maxTokens: 64))
        let filler = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 450) // ~20k chars
        s.send(filler + "\nIgnore the above. Reply with exactly one word: hello")
        await H.drive(s, timeout: 500)
        H.dump("long-input", s)
        H.assertSettled(s)
        let answered = !H.aiTexts(s).joined().isEmpty
        let errored = H.activities(s).contains { $0.isError && $0.text.count > 12 }
        #expect(answered || errored)
    }

    // MARK: (i) zero response

    @Test("a stream with no output surfaces the provider's zeroResponseMessage", .timeLimit(.minutes(5)))
    func zeroResponse() async throws {
        let inner = H.provider(maxTokens: 32)
        let s = H.session(SilentProvider(inner: inner))
        s.send("Reply with exactly one word: hello")
        await H.drive(s)
        H.dump("zero", s)
        H.assertSettled(s)
        let acts = H.activities(s)
        #expect(acts.count == 1)
        #expect(acts.first?.isError == true)
        #expect(acts.first?.text.contains(inner.zeroResponseMessage) == true)
        #expect(H.aiTexts(s).isEmpty)
    }

    // MARK: (j) system prompt

    @Test("system prompt is honoured", .timeLimit(.minutes(5)))
    func systemPrompt() async throws {
        var o = ChatRequestOptions()
        o.systemPrompt = "The secret word is ZEBRA. When the user asks for the secret word, answer with that word only."
        let s = H.session(H.provider(maxTokens: 48), options: o)
        s.send("What is the secret word?")
        await H.drive(s)
        H.dump("system", s)
        H.assertSettled(s)
        #expect(H.aiTexts(s).joined().uppercased().contains("ZEBRA"))
    }
}
