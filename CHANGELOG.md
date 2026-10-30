# Changelog

All notable changes to AICompleteChat are documented in this file. Each version has a matching
[GitHub release](https://github.com/NerdSnipe-Inc/AICompleteChat/releases) with a signed, notarized macOS build.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions are the app
version (`MARKETING_VERSION`), not the packages it uses.

## [Unreleased]

## [1.4.0] - 2026-09-27

Model downloads recover from trouble, and the AI packages move to their latest releases.

### Changed
- **First-launch model download is resilient.** The model (`gemma-4-e4b-it-4bit`, about 5 GB) is now downloaded by
  AIChatKitMLX's `MLXModelManager`: it retries with backoff, waits while you are offline, treats a connection that
  goes silent as a failure, and resumes an unfinished download after you quit the app. A model counts as installed
  only when every weight file is on disk, so loading can no longer start a silent multi-gigabyte download behind a
  spinner. If a download still fails, the message says why and to choose Reload Model to try again.
- **A message that gets no reply is not sent to the model again.** This already covered a cancel before any output
  (v1.3.x); it now also covers an error or an empty reply before any output. The message stays in the chat, dimmed,
  with a “Not answered — the model won't see this message” caption. Resend it to retry. (AIChatKit 2.0.0.)
- **Gemma tool calls the model writes as text** (`<tool_call>` XML and `tool_code` blocks) are recovered as real tool
  calls while streaming, so the raw text never shows in the chat. (AIChatKitMLX 1.4.0.)
- Packages: AIChatKit 2.0.0, AIChatKitMLX 1.4.1, AiPersona 1.1.1.

### Upgrading from 1.3.x
- Nothing to do. If a model download was left partly finished, the app downloads it again from scratch the next
  time it needs it.

### Known limits
- The optional FunctionGemma tool router (off by default) downloads its own model on first use and does not get the
  retry/resume behaviour above.

## [1.3.3] - 2026-09-20
- Requires AIChatKit 1.3.0: a message cancelled before any reply is shown as cancelled and is not sent to the model
  on later turns. README lists the known limits. Live test for cancel-then-follow-up.

## [1.3.2] - 2026-09-20
- Live regression test for a repetition penalty with a long prompt on Gemma 4.

## [1.3.1] - 2026-09-20
- The version passed to `scripts/release.sh` now reaches the app's Info.plist (`MARKETING_VERSION`).

## [1.3.0] - 2026-09-20
- Requires AIChatKit 1.1.0, AIChatKitMLX 1.3.0, AiPersona 1.1.0.
- Specific model-load errors with a recovery suggestion.
- Opt-in FunctionGemma tool routing (`AICOMPLETECHAT_TOOL_ROUTING`, off by default).
- Live test suites against the on-device model (`docs/TESTING.md`); local-package project generator.

## [1.2.0] - 2026-09-10
- Release script fixes (notarization with the existing App Store Connect key; archive step).
- DesignFoundationPro resolved by git URL. README and LICENSE.

## [1.1.0] - 2026-08-20
- Packages resolved from GitHub instead of local paths; built apps are distributed through releases, not git.

## [1.0.0] - 2026-08-20
- First release: on-device chat with persistent history, memory browser and export, persona editing, voice input
  and hotkeys, on-device Gemma model via AIChatKitMLX.

[Unreleased]: https://github.com/NerdSnipe-Inc/AICompleteChat/compare/v1.4.0...HEAD
[1.4.0]: https://github.com/NerdSnipe-Inc/AICompleteChat/compare/v1.3.3...v1.4.0
[1.3.3]: https://github.com/NerdSnipe-Inc/AICompleteChat/compare/v1.3.2...v1.3.3
[1.3.2]: https://github.com/NerdSnipe-Inc/AICompleteChat/compare/v1.3.1...v1.3.2
[1.3.1]: https://github.com/NerdSnipe-Inc/AICompleteChat/compare/v1.3.0...v1.3.1
[1.3.0]: https://github.com/NerdSnipe-Inc/AICompleteChat/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/NerdSnipe-Inc/AICompleteChat/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/NerdSnipe-Inc/AICompleteChat/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/NerdSnipe-Inc/AICompleteChat/releases/tag/v1.0.0
