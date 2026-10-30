# AICompleteChat — Design Spec

**Date:** 2026-08-18
**Author:** Daniel S
**Status:** Approved for implementation

---

## Overview

AICompleteChat is a new, standalone, production-quality macOS AI chat app. It exists to be two things at once:

1. A genuinely good, privacy-first on-device chat app — voice-enabled, memory-enabled, zero API keys, zero network calls for inference.
2. The flagship full-source example for both [`AiVoiceKit`](https://github.com/NerdSnipe-Inc/AiVoiceKit) (voice engine) and [`DesignFoundationPro`](https://nerdsnipe.cc/design-foundation-pro) (UI screens/shells) — a real app, not a demo shell, that both packages' users can read end-to-end.

It is **not** a wrapper around DesignFoundationPro's existing AIChat vertical as-is. That vertical (`DFAIChatRootView`, `DFAIChatThreadScreen`, `DFAIChatCompareScreen`, etc.) was built around comparing multiple cloud models (static `Claude`/`GPT-4o`/`Gemini` catalog, complete non-streaming responses). AICompleteChat requires real changes to that vertical to fit a single streaming on-device model, voice input, and a memory panel — those changes are in scope and approved, including breaking changes to DesignFoundationPro's public API for that vertical (major-version bump, CHANGELOG entry).

**Target platform:** macOS 15+ (matches the DMG/signed-app distribution requirement and AiVoiceKit's current platform support).

**Explicitly out of scope for this spec:** DMG signing/notarization and how the built artifact is referenced from AiVoiceKit's README — tracked as a separate bounded task once the app exists and works.

---

## Repo & Package Structure

New standalone repo: `~/Projects/AICompleteChat/` — its own local git repo, **no remote created or pushed** (matches how AiVoiceKit was set up: init locally, remote is a separate explicit step). Follows the same sibling-directory convention as `DFPlayground` and `FoundationDemo` (both live alongside `DesignFoundation`/`DesignFoundationPro` under `~/Projects`, not nested inside the package repos), and the same pattern Alric uses to consume AiVoiceKit.

### Local package dependencies (all via local SPM path references)

| Package | Location | Role |
|---|---|---|
| `DesignFoundation` | `~/Projects/DesignFoundation` | Design system tokens/primitives |
| `DesignFoundationPro` | `~/Projects/DesignFoundationPro` | AIChat vertical screens/shells (modified, see below) |
| `AIChatKit` (`AIChatCore`, `AIChatUI`) | `~/xCodeProjects/NerdSnipe-Inc-Packages/AIChatKit` | `ChatSession`, message model, streaming |
| `AIChatKitMLX` (`AIChatMLX`) | `~/xCodeProjects/NerdSnipe-Inc-Packages/AIChatKitMLX` | On-device MLX inference (`MLXProvider`) |
| `AiPersona` | `~/xCodeProjects/NerdSnipe-Inc-Packages/AiPersona` | Long-term memory (temporal knowledge graph, retrieval, fact extraction) |
| `AiVoiceKit` | `~/xCodeProjects/NerdSnipe-Inc-Packages/AiVoiceKit` | Voice dictation, hotkeys, command routing |

No `AIChatOpenAI`/`AIChatAnthropic` — this app makes zero outbound network calls for inference or memory extraction, by design.

---

## Model

On-device only, via `AIChatMLX.MLXProvider`:

- `MLXProvider.recommendedModelId()` picks the model for the current device automatically. On the ≥16GB RAM path this resolves to the larger MoE VLM; on the <16GB path (and this is the case we're building for, matching "e4b") it resolves to **`mlx-community/gemma-4-e4b-it-4bit`** (`MLXProvider.smallModelId`).
- The app does not hardcode a device-RAM branch — it defers to `MLXProvider`'s own selection logic, so behavior stays correct as that package's recommendation logic evolves. The Settings screen surfaces which model is active and why (RAM tier), not a picker between models.
- `MLXProvider` doubles as the extraction model AiPersona needs for fact extraction — no second model download.

---

## Architecture

**Composition root** (`AICompleteChatApp.swift`) builds once, at launch, and injects via SwiftUI environment:

```
MLXProvider (AIChatMLX)
    │
    ▼
ChatSession (AIChatUI) ──wraps──▶ PersonaChatCoordinator (new, this app)
    │                                   │
    │                                   ├─ before send(): PersonaPromptBuilder / RetrievalService
    │                                   │  (AiPersona) → memory-context fragment → folded into
    │                                   │  ChatRequestOptions.systemPrompt
    │                                   │
    │                                   └─ after turn completes: IngestionActor (AiPersona)
    │                                      runs in background → extracts facts → MemoryGraphStore
    │
VoiceEngineMacOS (AiVoiceKit)
    │
    ├─ onCommandReceived(text) ──▶ PersonaChatCoordinator.send(text)
    └─ onEditRequested(selected, instruction) ──▶ rewrite helper (LLMClient-style, via MLXProvider)
```

`PersonaChatCoordinator` is the **only new orchestration type** this app introduces. It does not reimplement `ChatSession`'s streaming/entries/isGenerating state — those stay owned by `ChatSession` (`AIChatUI`), read directly by the UI. It does not reimplement voice state — `VoiceEngineMacOS.state`/`.transcript` are read directly by the UI for the recording/waveform indicator. The coordinator's job is strictly: wire memory in before a send, and wire ingestion in after a response — two seams, not a god-object.

This deliberately avoids Approach A (a monolithic Alric-style engine duplicating `ChatSession`'s job) and Approach B (an actor-per-concern coordinator layer that's more ceremony than a showcase app needs) — see the design discussion for full rationale. Each underlying package keeps doing the job it already does well; the app layer stays thin.

---

## Screens — DesignFoundationPro AIChat Vertical Redesign

Breaking changes approved for this vertical. Major version bump + CHANGELOG entry when these land in DesignFoundationPro.

### `AIChatModels.swift`

- Remove the static `Claude`/`GPT-4o`/`Gemini` `AIChatModel` catalog (cloud, non-streaming shape).
- Replace with a single on-device model descriptor carrying load state:
  ```swift
  public struct AIChatOnDeviceModel: Identifiable, Sendable {
      public let id: String              // e.g. "gemma-4-e4b-it-4bit"
      public var displayName: String
      public var ramTier: String         // "≥16GB" / "<16GB"
      public var loadState: AIChatModelLoadState
  }
  public enum AIChatModelLoadState: Sendable {
      case notLoaded, downloading(progress: Double), ready, error(String)
  }
  ```
- `AIChatMessage` gains `sourceMemoryFacts: [String]` (optional, empty = no memory used this turn) so the UI can show provenance ("used memory: …") per message. `isStreaming` already exists and is reused as-is.
- New `MemorySnapshot` type: recent extracted facts + entity/edge counts, for the inspector panel. Backed by read-only queries against AiPersona's `MemoryGraphStore` — this type is UI-facing data, not a duplicate store.
- `groupConversations` (date-bucketing logic) is unchanged — it's provider-agnostic and already correct.

### `DFAIChatRootView`

Rebuilt on `DFThreeColumnShell` (`NavigationSplitView`-based: sidebar / list / detail):
- **Sidebar:** conversation date groups (Today / Yesterday / Previous 7 Days / Older), via existing `groupConversations`.
- **List:** conversation rows within the selected group.
- **Detail:** the thread screen (below).

### `DFAIChatThreadScreen`

- Wrapped in `DFRightInspectorShell` — togglable right panel hosts the Memory Inspector (see Compare screen repurposing, below).
- Adds a voice input affordance beside the existing text input: mic button, live partial-transcript display, and a recording/waveform state driven directly by `VoiceEngineMacOS.state`/`.transcript` (no new state duplicated in the screen).
- Streaming token rendering already fits `AIChatMessage.isStreaming` — reused as-is.

### `DFAIChatCompareScreen` → Memory Inspector

Repurposed rather than deleted. Its existing side-by-side layout primitives become the *content* of the `DFRightInspectorShell` panel: recent extracted facts, entity/edge summary counts, and per-message "this used memory" provenance (reading `AIChatMessage.sourceMemoryFacts`). This gives the screen a real, non-demo purpose instead of removing working layout code.

### `DFAIChatNewScreen` → first-run / empty state

- Model load progress, driven by `MLXProvider.loadModel(progressHandler:)` — download progress bar with cancel, load failure with retry.
- Mic + Accessibility permission prompts (required by AiVoiceKit for recording and global hotkeys/typed output) — inline, actionable, not a silent no-op.
- Starter prompts once the model is ready and no conversation is selected.

### `DFAIChatSettingsSheet`

- Voice hotkey configuration, reusing `VoiceHotkeyManager` (AiVoiceKit) — same settings-group pattern already shipped in Alric (`VoiceHotkeysSettingsView`).
- Model info (active model, RAM tier, reload/reset).
- Memory management: clear memory, export (AiPersona already has Notion export/import and knowledge-graph visualization export hooks — surfaced here, not reimplemented).

---

## Non-Happy States (Quality Gate item 12 applies directly)

Every one of these gets a real, designed state — not a placeholder — per DesignFoundationPro's own `QUALITY-GATE.md`:

- Model downloading (progress + cancel)
- Model load failure (retry)
- Mic permission denied (inline prompt with a path to System Settings, not silent failure)
- Accessibility permission denied (same)
- Empty conversation list
- Empty memory graph (no facts extracted yet)
- Voice recording error (e.g. no input device)
- Generation error / interrupted stream (network is irrelevant here, but model-load-lost-mid-generation, out-of-memory, etc. are real failure modes for on-device inference)

---

## Testing

- **Unit tests** for `PersonaChatCoordinator`: memory-fragment injection into the system prompt, and ingestion-triggering after a turn completes. `ChatSession` and `AiPersona`'s retrieval/ingestion surfaces are used behind their existing protocols/actors, so these are mockable without a real model load.
- **Unit tests** for the redesigned `AIChatModels` grouping/state logic (load-state transitions, `groupConversations` — largely already covered upstream, extended for the new types).
- **Previews with real fixtures** (Quality Gate item 13) for every screen and every non-happy state listed above — no lorem ipsum, no "Item 1".
- **Manual smoke pass** before calling any milestone done: launch → model loads → voice command → response streams → memory panel updates with a new fact. This is a macOS app; no XCUITest requirement beyond what's already normal for the user's other apps.

---

## Explicitly Deferred

- DMG signing, notarization, and Developer ID setup.
- How the built artifact is bundled with or referenced from AiVoiceKit (a GitHub Release asset once AiVoiceKit's remote exists is the likely mechanism, not a binary committed into package git history — but that decision belongs to its own bounded task, once the app exists and works).
- AiVoiceKit and AICompleteChat remote repo creation/push (both stay local-only until explicitly requested).
