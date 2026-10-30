import Foundation
import Testing
import AIChatCore
import AIChatMLX

/// Live negative tests: real MLX/Hub failures must surface as specific, actionable `ChatError`s,
/// and cancelling a stream must read as `.cancelled`, never as a failure.
@Suite("Live error handling", .serialized)
struct LiveErrorTests {

    @Test("Loading a nonexistent model id yields a specific, actionable error")
    func nonexistentModel() async throws {
        let provider = MLXProvider(modelId: "mlx-community/does-not-exist-xyz")
        do {
            try await provider.loadModel()
            Issue.record("Expected loadModel to throw")
        } catch let error as ChatError {
            print("[live/error] description=\(error.errorDescription ?? "nil")\n recovery=\(error.recoverySuggestion ?? "nil")\n debug=\(error.debugDescription)")
            switch error {
            case .modelNotFound(let id):
                #expect(id.contains("does-not-exist-xyz"))
            case .modelDownloadFailed:
                break // offline CI: still a specific download error
            default:
                Issue.record("Unexpected ChatError: \(error.debugDescription)")
            }
            #expect(error.errorDescription?.isEmpty == false)
            #expect(error.recoverySuggestion?.isEmpty == false)
            #expect(error.errorDescription?.contains("does-not-exist-xyz") == true
                    || error.underlyingError != nil)
        } catch {
            Issue.record("Error escaped unclassified: \(error)")
        }
    }

    @Test("Cancelling a stream mid-generation yields .cancelled, not a failure",
          .enabled(if: LiveModel.isCached, "gemma-4-e4b-it-4bit not in the Hugging Face cache"))
    func cancelMidStream() async throws {
        let provider = MLXProvider(modelId: LiveModel.id, maxTokens: 512)
        try await provider.loadModel()

        let task = Task { () -> (chunks: Int, error: Error?) in
            var chunks = 0
            do {
                let messages = [ChatMessage(role: .user, content: "Write a long story about a lighthouse keeper.")]
                for try await event in provider.stream(messages: messages, model: LiveModel.id, options: ChatRequestOptions()) {
                    if case .text = event {
                        chunks += 1
                        if chunks == 3 { withUnsafeCurrentTask { $0?.cancel() } }
                    }
                }
                return (chunks, nil)
            } catch {
                return (chunks, error)
            }
        }
        let result = await task.value
        #expect(result.chunks >= 3)
        // A cancelled consumer's iterator simply ends (AsyncThrowingStream semantics), so the
        // stream may finish silently; what must never happen is a *failure* being reported, and
        // generation must actually stop well short of the 512-token budget.
        if let error = result.error {
            guard case ChatError.cancelled = error else {
                Issue.record("Cancellation surfaced as a failure: \(error)")
                return
            }
        }
        #expect(result.chunks < 100, "generation kept running after cancellation (\(result.chunks) chunks)")
    }
}
