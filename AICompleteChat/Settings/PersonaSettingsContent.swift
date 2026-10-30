import SwiftUI
import DesignFoundation
import AiPersona

/// Persona-editing block embedded in `DFAIChatSettingsSheet`'s "Persona" tab. `PersonaStore`
/// is `@MainActor @Observable` (not `ObservableObject`), so there's no `$store.name`-style binding
/// support via `@Bindable` needed here — this view only reads the store's current values once (at
/// init, into local `@State`) and calls `update(name:personality:)` explicitly, so a plain `let`
/// reference is the correct wrapper (or lack thereof).
struct PersonaSettingsContent: View {
    let personaStore: PersonaStore
    /// Called after `personaStore.userName` actually changes, so the caller can also update the
    /// memory graph (a "the user's name is X" entity + fact) — `PersonaSettingsContent` itself has
    /// no access to `MemoryGraphStore`, by design; persona editing and memory writes stay separate
    /// concerns.
    var onUserNameSaved: (String) -> Void = { _ in }
    @State private var userName: String
    @State private var name: String
    @State private var personality: String

    @Environment(\.dfTheme) private var theme

    init(personaStore: PersonaStore, onUserNameSaved: @escaping (String) -> Void = { _ in }) {
        self.personaStore = personaStore
        self.onUserNameSaved = onUserNameSaved
        self._userName = State(initialValue: personaStore.userName)
        self._name = State(initialValue: personaStore.name)
        self._personality = State(initialValue: personaStore.personality)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.md) {
            Text("About You")
                .font(theme.typography.sectionTitle(isDesktop: true))
                .foregroundStyle(theme.colors.textPrimary)

            DFTextField("Your Name", text: $userName)
                .onSubmit(save)

            Divider()

            Text("Persona")
                .font(theme.typography.sectionTitle(isDesktop: true))
                .foregroundStyle(theme.colors.textPrimary)

            DFTextField("Name", text: $name)
                .onSubmit(save)

            VStack(alignment: .leading, spacing: theme.spacing.xs) {
                Label("Personality", systemImage: "text.quote")
                    .font(theme.typography.caption.font)
                    .foregroundStyle(theme.colors.textSecondary)
                TextEditor(text: $personality)
                    .font(theme.typography.label.font)
                    .foregroundStyle(theme.colors.textPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 72)
                    .padding(theme.spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: theme.radius.md)
                            .fill(theme.colors.surface)
                            .overlay(
                                RoundedRectangle(cornerRadius: theme.radius.md)
                                    .stroke(theme.colors.border, lineWidth: 1)
                            )
                    )
                    .onSubmit(save)
            }

            DFButton("Save", action: save)
                .dfButtonStyle(.filled)
        }
    }

    private func save() {
        if personaStore.updateUserName(userName) {
            onUserNameSaved(personaStore.userName)
        }
        personaStore.update(name: name, personality: personality)
    }
}
