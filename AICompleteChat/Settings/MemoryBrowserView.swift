import SwiftUI
import DesignFoundation
import AiPersona

/// Lets the user see and correct what the on-device memory graph actually knows: browse every
/// entity and active fact, edit or delete either, and add a new entity by hand. Without this the
/// memory graph is a black box — the user has no way to see what was extracted about them, let
/// alone fix something wrong.
struct MemoryBrowserView: View {
    let memoryStore: MemoryGraphStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dfTheme) private var theme

    @State private var entities: [EntityNode] = []
    @State private var facts: [FactEdge] = []
    @State private var editingEntity: EntityNode?
    @State private var editingFact: FactEdge?
    @State private var isAddingEntity = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Memory")
                    .font(theme.typography.title.font)
                    .fontWeight(.semibold)
                    .foregroundStyle(theme.colors.textPrimary)
                Spacer()
                DFButton("Add Entity", style: .outlined) { isAddingEntity = true }
                DFButton("Done") { dismiss() }
                    .dfButtonStyle(.filled)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(theme.spacing.lg)

            Divider().foregroundStyle(theme.colors.border)

            ScrollView {
                VStack(alignment: .leading, spacing: theme.spacing.lg) {
                    entitiesSection
                    factsSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(theme.spacing.lg)
            }
            .background(theme.colors.background)
        }
        .background(theme.colors.background)
        .frame(minWidth: 620, idealWidth: 680, minHeight: 520, idealHeight: 640)
        .onAppear(perform: reload)
        .sheet(item: $editingEntity) { entity in
            EntityEditSheet(entity: entity, memoryStore: memoryStore, onDone: reload)
        }
        .sheet(item: $editingFact) { fact in
            FactEditSheet(fact: fact, memoryStore: memoryStore, onDone: reload)
        }
        .sheet(isPresented: $isAddingEntity) {
            EntityEditSheet(entity: nil, memoryStore: memoryStore, onDone: reload)
        }
    }

    private var entitiesSection: some View {
        DFCard {
            VStack(alignment: .leading, spacing: theme.spacing.sm) {
                Text("Entities")
                    .font(theme.typography.sectionTitle(isDesktop: true))
                    .foregroundStyle(theme.colors.textPrimary)

                if entities.isEmpty {
                    Text("No entities yet — they're extracted automatically as you chat.")
                        .font(theme.typography.caption.font)
                        .foregroundStyle(theme.colors.textSecondary)
                } else {
                    ForEach(entities, id: \.id) { entity in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entity.name)
                                    .foregroundStyle(theme.colors.textPrimary)
                                if !entity.summary.isEmpty {
                                    Text(entity.summary)
                                        .font(theme.typography.caption.font)
                                        .foregroundStyle(theme.colors.textSecondary)
                                }
                            }
                            Spacer()
                            Button { editingEntity = entity } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.plain)
                            Button {
                                memoryStore.deleteEntity(id: entity.id)
                                reload()
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(theme.colors.destructive)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, theme.spacing.xs)
                        if entity.id != entities.last?.id { Divider() }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var factsSection: some View {
        DFCard {
            VStack(alignment: .leading, spacing: theme.spacing.sm) {
                Text("Facts")
                    .font(theme.typography.sectionTitle(isDesktop: true))
                    .foregroundStyle(theme.colors.textPrimary)

                if facts.isEmpty {
                    Text("No active facts yet.")
                        .font(theme.typography.caption.font)
                        .foregroundStyle(theme.colors.textSecondary)
                } else {
                    ForEach(facts, id: \.id) { fact in
                        HStack {
                            Text(fact.factText)
                                .foregroundStyle(theme.colors.textPrimary)
                            Spacer()
                            Button { editingFact = fact } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.plain)
                            Button {
                                memoryStore.invalidateFact(id: fact.id)
                                reload()
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(theme.colors.destructive)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, theme.spacing.xs)
                        if fact.id != facts.last?.id { Divider() }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func reload() {
        entities = memoryStore.allEntities()
        facts = memoryStore.activeFacts()
    }
}

/// Add or edit an entity's name and summary.
private struct EntityEditSheet: View {
    let entity: EntityNode?
    let memoryStore: MemoryGraphStore
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dfTheme) private var theme

    @State private var name: String
    @State private var summary: String

    init(entity: EntityNode?, memoryStore: MemoryGraphStore, onDone: @escaping () -> Void) {
        self.entity = entity
        self.memoryStore = memoryStore
        self.onDone = onDone
        self._name = State(initialValue: entity?.name ?? "")
        self._summary = State(initialValue: entity?.summary ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.md) {
            Text(entity == nil ? "Add Entity" : "Edit Entity")
                .font(theme.typography.title.font)
                .fontWeight(.semibold)
                .foregroundStyle(theme.colors.textPrimary)

            DFTextField("Name", text: $name)
            DFTextField("Summary", text: $summary)

            HStack {
                Spacer()
                DFButton("Cancel", style: .outlined) { dismiss() }
                DFButton("Save") {
                    if let entity {
                        memoryStore.updateEntity(id: entity.id, name: name, summary: summary)
                    } else {
                        memoryStore.upsertEntity(name: name, summary: summary, kind: .other, embedding: [])
                    }
                    onDone()
                    dismiss()
                }
                .dfButtonStyle(.filled)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(theme.spacing.lg)
        .frame(minWidth: 380, minHeight: 200)
        .background(theme.colors.background)
    }
}

/// Correct a fact's text in place.
private struct FactEditSheet: View {
    let fact: FactEdge
    let memoryStore: MemoryGraphStore
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dfTheme) private var theme

    @State private var factText: String

    init(fact: FactEdge, memoryStore: MemoryGraphStore, onDone: @escaping () -> Void) {
        self.fact = fact
        self.memoryStore = memoryStore
        self.onDone = onDone
        self._factText = State(initialValue: fact.factText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.md) {
            Text("Edit Fact")
                .font(theme.typography.title.font)
                .fontWeight(.semibold)
                .foregroundStyle(theme.colors.textPrimary)

            DFTextField("Fact", text: $factText)

            HStack {
                Spacer()
                DFButton("Cancel", style: .outlined) { dismiss() }
                DFButton("Save") {
                    memoryStore.updateFact(id: fact.id, factText: factText)
                    onDone()
                    dismiss()
                }
                .dfButtonStyle(.filled)
                .disabled(factText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(theme.spacing.lg)
        .frame(minWidth: 380, minHeight: 160)
        .background(theme.colors.background)
    }
}
