import SwiftUI
import AiPersona

/// Persona-editing block embedded in `DFAIChatSettingsSheet`'s "Persona" section. `PersonaStore`
/// is `@MainActor @Observable` (not `ObservableObject`), so there's no `$store.name`-style binding
/// support via `@Bindable` needed here — this view only reads the store's current values once (at
/// init, into local `@State`) and calls `update(name:personality:)` explicitly, so a plain `let`
/// reference is the correct wrapper (or lack thereof).
struct PersonaSettingsContent: View {
    let personaStore: PersonaStore
    @State private var name: String
    @State private var personality: String

    init(personaStore: PersonaStore) {
        self.personaStore = personaStore
        self._name = State(initialValue: personaStore.name)
        self._personality = State(initialValue: personaStore.personality)
    }

    var body: some View {
        TextField("Name", text: $name)
            .onSubmit { personaStore.update(name: name, personality: personality) }
        TextField("Personality", text: $personality, axis: .vertical)
            .lineLimit(3...6)
            .onSubmit { personaStore.update(name: name, personality: personality) }
        Button("Save") {
            personaStore.update(name: name, personality: personality)
        }
    }
}
