# AICompleteChat

A full-source, production-quality example of a fully on-device AI chat app for macOS. No cloud
dependency once the model is downloaded — chat, voice dictation, and memory all run locally.

**Just want to try it?** Skip building from source — grab the signed, notarized build from the
[latest release](https://github.com/NerdSnipe-Inc/AICompleteChat/releases/latest), unzip, and run
it directly. No DesignFoundationPro license needed for this — that's only required to build from
source (see below).

## What it does

- **On-device inference** via MLX (`mlx-community/gemma-4-e4b-it-4bit`), downloaded from Hugging
  Face the first time you launch it and cached locally after that — every launch after the first
  is fully offline.
- **Persistent chat history** — conversations survive across launches, with delete support.
- **Voice dictation and commands** via [AiVoiceKit](https://github.com/NerdSnipe-Inc/AiVoiceKit) —
  on-device speech recognition, global hotkeys, AI-assisted rewriting of selected text in any app.
- **Persistent memory** via [AiPersona](https://github.com/NerdSnipe-Inc/AiPersona) — a bi-temporal knowledge graph that extracts facts and
  entities from conversations, retrieves relevant ones per turn, and lets you browse, correct, or
  delete anything it's learned (Settings → Memory → Browse memory). It also remembers who you are:
  set your name once and it becomes a real fact in the graph, not just a settings field.
- **A UI assembled from a real design system**, not built from scratch — see below.

## Requirements

- macOS 15+, Apple Silicon (MLX doesn't run meaningfully on Intel)
- Xcode 26+
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) — this repo has no
  committed `.xcodeproj`; regenerate it from `project.yml`
- **A [DesignFoundationPro](https://nerdsnipe.cc/design-foundation-pro) license.** This
  is the one intentional gate: the source here is meant to be read and learned from by anyone, but
  it only actually *builds* for someone with access to DesignFoundationPro, since the entire UI is
  assembled from its `AIChat` vertical rather than built from scratch.

  Without access, package resolution fails outright — you'll see something like this during
  `xcodegen generate` + build, or from Xcode's own package resolution:
  ```
  error: Failed to clone repository https://github.com/NerdSnipe-Inc/DesignFoundationPro.git:
      remote: Repository not found.
      fatal: repository 'https://github.com/NerdSnipe-Inc/DesignFoundationPro.git/' not found
  ```
  (If you have no GitHub credentials configured in git at all, the underlying git error reads
  `could not read Username for 'https://github.com': terminal prompts disabled` instead — same
  cause, just failing one step earlier.) That's expected, not a bug in this repo: it means your
  GitHub account isn't on DesignFoundationPro's access list. [Grab a
  license](https://nerdsnipe.cc/design-foundation-pro) to fix it, or just [download the
  signed build](https://github.com/NerdSnipe-Inc/AICompleteChat/releases/latest) above instead.

Every other dependency is public and resolves automatically via Swift Package Manager:
[DesignFoundation](https://github.com/NerdSnipe-Inc/design-foundation) (the free design-system
core), [AIChatKit](https://github.com/NerdSnipe-Inc/AIChatKit) /
[AIChatKitMLX](https://github.com/NerdSnipe-Inc/AIChatKitMLX) (chat session + MLX provider),
[AiPersona](https://github.com/NerdSnipe-Inc/AiPersona) (memory graph), and
[AiVoiceKit](https://github.com/NerdSnipe-Inc/AiVoiceKit) (voice).

## Building

```sh
git clone https://github.com/NerdSnipe-Inc/AICompleteChat.git
cd AICompleteChat
xcodegen generate
open AICompleteChat.xcodeproj
```

Build and run the `AICompleteChat` scheme. First launch downloads the model from Hugging Face
(several GB) — you'll see real download progress, not just a spinner.

## Architecture

```
AICompleteChat/
  ContentView.swift          — bridges AIChatKit's ChatSession to DesignFoundationPro's AIChat UI
  Engine/
    AppEnvironment.swift     — owns the MLX provider, chat session, memory store, voice engine
    PersonaChatCoordinator.swift — folds persona identity + retrieved memory into every prompt
  Core/
    ChatHistoryStore.swift   — SwiftData-backed chat persistence
  Settings/                  — voice model picker, persona editor, memory browser
```

The UI itself lives in DesignFoundationPro's `AIChat` vertical (`DFAIChatRootView` and friends) —
this app wires real data into it rather than reimplementing chat UI from scratch. See
DesignFoundationPro's own docs for how that vertical is put together.

## Known limits

- **First launch needs the model.** The app uses `mlx-community/gemma-4-e4b-it-4bit` (about 5 GB; the local snapshot is 4.8 GB), downloaded through the Hugging Face cache on first launch. The live tests are skipped, not failed, when it isn't cached. See [docs/TESTING.md](docs/TESTING.md).
- **FunctionGemma tool routing is experimental and off by default.** Enable it with `defaults write com.nerdsnipe.aicompletechat AICOMPLETECHAT_TOOL_ROUTING -bool YES`. Read [AIChatKitMLX's TOOL_ROUTING.md](https://github.com/NerdSnipe-Inc/AIChatKitMLX/blob/main/docs/TOOL_ROUTING.md) first for the measured accuracy and latency.
- **Router benchmarks are opt-in.** The router accuracy/latency live tests only run with `ROUTING_BENCHMARK=1`; the other routing tests run whenever both models are cached.
- **A message cancelled before any reply is not sent to the model on later turns.** It stays in the transcript, shown dimmed with a “Cancelled — the model won't see this message” caption (AIChatKit 1.3.0+; the flag is `UserEntry.isCancelled`; the drop from provider history is AIChatKit 1.2.0+). Resend it if you still want an answer.

Building from source also requires DesignFoundationPro access, see [Requirements](#requirements).

## License

MIT — see [LICENSE](LICENSE). Note this only covers the code in *this* repo; DesignFoundationPro,
AiPersona, and AiVoiceKit are each licensed separately (see their own repos).
