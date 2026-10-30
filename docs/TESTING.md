# Testing AICompleteChat and the AIChatKit / AiPersona stack

Everything below is fully automated and headless. The live tests drive the real on-device
`mlx-community/gemma-4-e4b-it-4bit` model and are skipped (not failed) when it isn't in the
Hugging Face cache (`~/.cache/huggingface/hub`).

## One-time
`scripts/generate-local-project.sh` — generates the Xcode project wired to the local sibling
packages (AIChatKit, AIChatKitMLX, AiPersona, AiVoiceKit) so package edits are picked up.
`project.yml` stays pointed at the published GitHub tags. Re-run it after adding test files.

## Run
```sh
# Whole app suite: fakes + live gemma-4-e4b (chat, thinking, tool loop, persona, errors)
xcodebuild test -project AICompleteChat.xcodeproj -scheme AICompleteChat \
  -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation

# One suite
... -only-testing:AICompleteChatTests/LiveSessionTests

# Package suites (plain `swift test` cannot load MLX Metal shaders — use xcodebuild)
cd ../AIChatKit    && xcodebuild test -scheme AIChatKit-Package -destination 'platform=macOS' -skipMacroValidation
cd ../AIChatKitMLX && xcodebuild test -scheme AIChatKitMLX      -destination 'platform=macOS' -skipMacroValidation
cd ../AiPersona    && xcodebuild test -scheme AiPersona         -destination 'platform=macOS' -skipMacroValidation
```
Router accuracy/latency benchmarks in `LiveRoutingTests` only run with `ROUTING_BENCHMARK=1` set in the environment.
`-skipMacroValidation` is required headless: it trusts the `MLXHuggingFaceMacros` macro.

## Live suites (AICompleteChatTests)
| Suite | Covers |
|---|---|
| `LiveGemma4Tests` | provider: load, chat, multi-turn, thinking, tool call |
| `LiveSessionTests` | `ChatSession`: tool loop, parallel calls, cancel, odd input, long chats |
| `LivePersonaTests` | AiPersona: extraction, corrections, retrieval, coordinator, load failure |
| `LiveErrorTests` | specific user-facing errors, cancellation is never an error |

## Debugging a failure
Set `AICHAT_DEBUG=1` (or `ChatLog.debugMode = true`), then:
`log stream --level debug --predicate 'subsystem BEGINSWITH "cc.nerdsnipe"'`.
Error/`ChatError` reference: `AIChatKit/docs/ERRORS_AND_LOGGING.md`.
Session semantics: `AIChatKit/docs/CHAT_SESSION_BEHAVIOUR.md`. Persona layer: `AiPersona/docs/`.
