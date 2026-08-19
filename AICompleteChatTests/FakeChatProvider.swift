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
