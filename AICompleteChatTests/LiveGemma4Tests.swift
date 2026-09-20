import Foundation
import Testing
import AIChatCore
import AIChatMLX

/// Live, fully automated tests against the real on-device `gemma-4-e4b-it-4bit` model, exercised
/// through the same `MLXProvider` the app uses. They need the model weights in the Hugging Face
/// cache (`~/.cache/huggingface/hub/models--mlx-community--gemma-4-e4b-it-4bit`) and are skipped
/// with a clear message when that cache is absent, so they never fail a machine that simply
/// hasn't downloaded the model.
enum LiveModel {
    static let id = MLXProvider.smallModelId

    static var isCached: Bool {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/models--mlx-community--gemma-4-e4b-it-4bit/snapshots")
        return (try? FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty) == false
    }

    struct Collected {
        var text = ""
        var reasoning = ""
        var toolCalls: [(id: String, name: String, arguments: String)] = []
        var events: [ChatStreamEvent] = []
        var finishedNormally = false
    }

    static func collect(
        _ provider: MLXProvider, _ messages: [ChatMessage], options: ChatRequestOptions = ChatRequestOptions()
    ) async throws -> Collected {
        var out = Collected()
        for try await event in provider.stream(messages: messages, model: id, options: options) {
            out.events.append(event)
            switch event {
            case .text(let t): out.text += t
            case .reasoning(let r): out.reasoning += r
            case .toolCallComplete(let id, let name, let args): out.toolCalls.append((id, name, args))
            case .done: out.finishedNormally = true
            default: break
            }
        }
        return out
    }
}

@Suite("Live gemma-4-e4b", .serialized, .enabled(if: LiveModel.isCached, "gemma-4-e4b-it-4bit not in HF cache"))
struct LiveGemma4Tests {

    @Test("model loads", .timeLimit(.minutes(5)))
    func loads() async throws {
        let provider = MLXProvider(modelId: LiveModel.id)
        try await provider.loadModel()
    }

    @Test("plain chat streams a non-empty answer and finishes", .timeLimit(.minutes(5)))
    func chat() async throws {
        let provider = MLXProvider(modelId: LiveModel.id, maxTokens: 128, temperature: 0.2)
        let result = try await LiveModel.collect(
            provider,
            [ChatMessage(role: .user, content: "Reply with exactly one word: hello")]
        )
        print("[live/chat] events=\(result.events.count) text=\(result.text.debugDescription)")
        #expect(!result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(result.finishedNormally)
        #expect(result.reasoning.isEmpty, "thinking is off by default, no reasoning expected")
    }

    /// Regression: with `repetitionPenalty` set, mlx-swift-lm < 3.31.4 corrupted the penalty's token
    /// ring on Gemma 4's `[1, N]` prompt array and crashed on the first sampled token
    /// (`[broadcast_shapes] Shapes (20) and (N+19)`). The prompt must be far longer than the
    /// penalty's 20-token window so a mis-sized buffer can't line up with it by accident.
    @Test("repetition penalty with a long prompt does not crash and still answers", .timeLimit(.minutes(5)))
    func repetitionPenaltyLongPrompt() async throws {
        let provider = MLXProvider(modelId: LiveModel.id, maxTokens: 64, temperature: 0.2, repetitionPenalty: 1.1)
        let filler = String(repeating: "The quick brown fox jumps over the lazy dog near the riverbank. ", count: 40)
        let result = try await LiveModel.collect(
            provider,
            [ChatMessage(role: .user, content: filler + "\nIgnore the text above. Reply with exactly one word: hello")]
        )
        print("[live/repetition] events=\(result.events.count) text=\(result.text.debugDescription)")
        #expect(!result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(result.finishedNormally)
    }

    @Test("multi-turn chat keeps context", .timeLimit(.minutes(5)))
    func multiTurn() async throws {
        let provider = MLXProvider(modelId: LiveModel.id, maxTokens: 128, temperature: 0.1)
        let history: [ChatMessage] = [
            ChatMessage(role: .user, content: "My favourite colour is teal. Just say OK."),
            ChatMessage(role: .assistant, content: "OK"),
            ChatMessage(role: .user, content: "What is my favourite colour? One word."),
        ]
        let result = try await LiveModel.collect(provider, history)
        print("[live/multiTurn] text=\(result.text.debugDescription)")
        #expect(result.text.lowercased().contains("teal"))
    }

    @Test("thinking emits reasoning events separate from the answer", .timeLimit(.minutes(5)))
    func thinking() async throws {
        let provider = MLXProvider(modelId: LiveModel.id, maxTokens: 512, temperature: 0.2, enableThinking: true)
        let result = try await LiveModel.collect(
            provider,
            [ChatMessage(role: .user, content: "What is 17 * 23? Think it through, then answer with just the number.")]
        )
        print("[live/thinking] reasoning=\(result.reasoning.debugDescription)\n text=\(result.text.debugDescription)")
        #expect(!result.reasoning.isEmpty, "expected .reasoning events with enableThinking = true")
        #expect(result.text.contains("391"))
        #expect(!result.text.contains("<|channel"), "raw channel markers must never leak into the answer")
    }

    @Test("tool call is emitted with parsed JSON arguments", .timeLimit(.minutes(5)))
    func toolCall() async throws {
        let provider = MLXProvider(modelId: LiveModel.id, maxTokens: 256, temperature: 0.0)
        let weather: [String: any Sendable] = [
            "type": "function",
            "function": [
                "name": "get_weather",
                "description": "Get the current weather for a city.",
                "parameters": [
                    "type": "object",
                    "properties": ["city": ["type": "string", "description": "City name"] as [String: any Sendable]] as [String: any Sendable],
                    "required": ["city"],
                ] as [String: any Sendable],
            ] as [String: any Sendable],
        ]
        var options = ChatRequestOptions()
        options.nativeToolSpecs = [weather]
        let result = try await LiveModel.collect(
            provider,
            [ChatMessage(role: .user, content: "What's the weather in Paris right now? Use the tool.")],
            options: options
        )
        print("[live/toolCall] calls=\(result.toolCalls) text=\(result.text.debugDescription)")
        let call = try #require(result.toolCalls.first, "model should have called get_weather")
        #expect(call.name == "get_weather")
        let args = try #require(
            try JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: Any],
            "arguments must be valid JSON: \(call.arguments)"
        )
        #expect((args["city"] as? String)?.lowercased().contains("paris") == true)
    }
}
