import Combine
import SwiftUI
import DesignFoundation
import AiVoiceKit

#if os(macOS)
import ApplicationServices
import AppKit

// MARK: - ShortcutRecorder

/// Manages NSEvent monitor lifecycle outside the SwiftUI value type (coordinator pattern).
/// Ported verbatim from Alric's `VoiceHotkeysSettingsView.swift` (proven, shipped implementation
/// against the same `VoiceHotkeyManager`/`HotkeyShortcut` API in AiVoiceKit).
@MainActor
private final class ShortcutRecorder: ObservableObject {
    @Published var isRecording = false
    @Published var recordingMessage = ""

    var onCommit: ((HotkeyShortcut) -> Void)?

    // Swift 6 strict concurrency: `deinit` on a class is always nonisolated, even for a
    // @MainActor-isolated class — accessing a non-Sendable `Any?` there needs an explicit
    // opt-out. Safe here: by the time deinit runs, no other code holds a reference to this
    // instance, so there's no actual concurrent access to race with.
    private nonisolated(unsafe) var eventMonitor: Any?
    private var pendingModifierFlags: NSEvent.ModifierFlags = []
    private var pendingModifierKeyCodes: Set<UInt16> = []
    private var pendingModifierKeyCode: UInt16?
    private var pendingModifierOnly = false
    private var currentRecordingModifierKeyCodes: Set<UInt16> = []

    func start() {
        isRecording = true
        recordingMessage = ""
        resetPending()
        removeMonitor()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handle(event)
        }
    }

    func cancel() {
        isRecording = false
        recordingMessage = ""
        resetPending()
        removeMonitor()
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift, .function])
        switch event.type {
        case .keyDown:      return handleKeyDown(event, mods: mods)
        case .flagsChanged: return handleFlagsChanged(event, mods: mods)
        default:            return event
        }
    }

    private func handleKeyDown(_ event: NSEvent, mods: NSEvent.ModifierFlags) -> NSEvent? {
        if event.keyCode == 53 { cancel(); return nil } // Escape
        commit(HotkeyShortcut(keyCode: event.keyCode, modifierFlags: pendingModifierFlags.union(mods)))
        return nil
    }

    private func handleFlagsChanged(_ event: NSEvent, mods: NSEvent.ModifierFlags) -> NSEvent? {
        if mods.isEmpty {
            if pendingModifierOnly, let code = pendingModifierKeyCode {
                commit(HotkeyShortcut(
                    keyCode: code,
                    modifierFlags: pendingModifierFlags,
                    modifierKeyCodes: Array(pendingModifierKeyCodes)
                ))
            } else {
                resetPending()
            }
            return nil
        }
        if !currentRecordingModifierKeyCodes.contains(event.keyCode) {
            currentRecordingModifierKeyCodes.insert(event.keyCode)
            pendingModifierKeyCodes.insert(event.keyCode)
            pendingModifierFlags = pendingModifierFlags.union(mods)
            pendingModifierKeyCode = event.keyCode
            pendingModifierOnly = true
        }
        return nil
    }

    private func commit(_ shortcut: HotkeyShortcut) {
        isRecording = false
        recordingMessage = ""
        resetPending()
        removeMonitor()
        onCommit?(shortcut)
    }

    private func resetPending() {
        pendingModifierFlags = []
        pendingModifierKeyCodes = []
        pendingModifierKeyCode = nil
        pendingModifierOnly = false
        currentRecordingModifierKeyCodes = []
    }

    private func removeMonitor() {
        if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
    }

    deinit { if let m = eventMonitor { NSEvent.removeMonitor(m) } }
}

// MARK: - VoiceHotkeysSettingsContent

/// Global-hotkey settings block embedded in `DFAIChatSettingsSheet`'s voice section.
/// Adapted from Alric's shipped `VoiceHotkeysSettingsView` — same `VoiceHotkeyManager`/
/// `VoiceSettingsStore`/`HotkeyShortcut` API from AiVoiceKit, restyled onto DesignFoundationPro's
/// `dfTheme` color tokens instead of Alric's named xcasset colorsets (this app has no
/// `alricTextPrimary`-style tokens; `theme.colors.*` is the equivalent surface here).
struct VoiceHotkeysSettingsContent: View {
    @ObservedObject var voiceEngine: VoiceEngineMacOS
    @ObservedObject private var store = VoiceSettingsStore.shared
    @StateObject private var recorder = ShortcutRecorder()
    @State private var accessibilityEnabled = AXIsProcessTrusted()
    @Environment(\.dfTheme) private var theme

    var body: some View {
        sectionCard {
            sectionLabel("Global Hotkeys", icon: "keyboard")
            accessibilityStatusRow
            Divider().opacity(0.25)
            dictationShortcutRow
            Divider().opacity(0.25)
            activationModeRow
            Divider().opacity(0.25)
            otherShortcutsBlock
        }
        .onAppear {
            accessibilityEnabled = AXIsProcessTrusted()
            recorder.onCommit = { shortcut in
                store.hotkeyShortcut = shortcut
                voiceEngine.updateHotkeyShortcut(shortcut)
            }
        }
        .onDisappear { recorder.cancel() }
    }

    // MARK: - Accessibility row

    private var accessibilityStatusRow: some View {
        HStack(spacing: 10) {
            Image(systemName: accessibilityEnabled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(accessibilityEnabled ? theme.colors.success : theme.colors.warning)
                .font(.system(size: 14))
            VStack(alignment: .leading, spacing: 2) {
                Text("Accessibility Permission")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(theme.colors.textPrimary)
                Text(accessibilityEnabled
                    ? "Global hotkeys are active."
                    : "Required for global hotkey capture.")
                    .font(.caption)
                    .foregroundStyle(theme.colors.textSecondary)
            }
            Spacer()
            if !accessibilityEnabled {
                Button("Open Settings") {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(accessibilityEnabled
            ? theme.colors.success.opacity(0.08)
            : theme.colors.warning.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Dictation Shortcut Row

    private var dictationShortcutRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.colors.textSecondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Dictation Shortcut")
                        .font(.subheadline)
                        .foregroundStyle(theme.colors.textPrimary)
                    Text("The key that triggers voice recording globally.")
                        .font(.caption)
                        .foregroundStyle(theme.colors.textSecondary)
                }
                Spacer()
                if recorder.isRecording {
                    shortcutCapturePill
                } else {
                    shortcutDisplayPill(store.hotkeyShortcut.displayString)
                }
                Button(recorder.isRecording ? "Cancel" : "Change") {
                    if recorder.isRecording { recorder.cancel() } else { recorder.start() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            if recorder.isRecording && !recorder.recordingMessage.isEmpty {
                Text(recorder.recordingMessage)
                    .font(.caption)
                    .foregroundStyle(theme.colors.warning)
                    .padding(.leading, 28)
            }
        }
    }

    private var shortcutCapturePill: some View {
        Text("Press shortcut…")
            .font(.caption.weight(.medium))
            .foregroundStyle(.orange)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.orange.opacity(0.2))
            )
    }

    private func shortcutDisplayPill(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospaced().weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.quaternary.opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                    )
            )
    }

    // MARK: - Activation Mode

    private var activationModeRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Activation Mode")
                    .font(.subheadline)
                    .foregroundStyle(theme.colors.textPrimary)
                Text(store.hotkeyActivationMode.hint)
                    .font(.caption)
                    .foregroundStyle(theme.colors.textSecondary)
            }
            Spacer()
            Picker("", selection: $store.hotkeyActivationMode) {
                ForEach(HotkeyActivationMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 160)
        }
    }

    // MARK: - Other Shortcuts (info only)

    private var otherShortcutsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Other Shortcuts")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.colors.textSecondary)
            infoShortcutRow(icon: "terminal.fill",      title: "Command Mode",     note: "Hold dictation shortcut and say 'Alric, …'")
            infoShortcutRow(icon: "pencil.and.outline", title: "Edit Mode",        note: "Select text, then trigger dictation shortcut")
            infoShortcutRow(icon: "xmark.circle",       title: "Cancel Recording", note: "Escape while recording")
        }
    }

    private func infoShortcutRow(icon: String, title: String, note: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(theme.colors.textSecondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(theme.colors.textPrimary)
                Text(note)
                    .font(.caption)
                    .foregroundStyle(theme.colors.textSecondary)
            }
            Spacer()
        }
    }

    // MARK: - Shared helpers

    @ViewBuilder
    private func sectionCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.colors.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func sectionLabel(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(theme.colors.textPrimary)
    }
}

// MARK: - HotkeyActivationMode display helpers

private extension HotkeyActivationMode {
    var hint: String {
        switch self {
        case .holdToRecord: return "Hold the hotkey to record; release to transcribe."
        case .toggle:       return "Press once to start, press again to stop."
        case .doubleTap:    return "Double-tap the hotkey to start or stop recording."
        }
    }
}

// MARK: - Preview

#Preview {
    ScrollView {
        VoiceHotkeysSettingsContent(voiceEngine: VoiceEngineMacOS(onCommandReceived: { _ in }))
            .padding(20)
    }
    .frame(width: 640, height: 500)
    .preferredColorScheme(.dark)
}

#else

struct VoiceHotkeysSettingsContent: View {
    let voiceEngine: VoiceEngineMacOS
    var body: some View { EmptyView() }
}

#endif
