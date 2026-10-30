import Foundation
import AiPersona
import DesignFoundationPro

@MainActor
enum MemorySnapshotProvider {
    /// Reads directly from `store` — no separate cache, so this always reflects the latest
    /// ingested facts. Cheap enough to call on every Memory Inspector panel appearance.
    static func snapshot(from store: MemoryGraphStore, limit: Int = 10) -> MemorySnapshot {
        let facts = store.activeFacts()
        let recent = facts
            .sorted { $0.validAt > $1.validAt }
            .prefix(limit)
            .map(\.factText)
        return MemorySnapshot(
            recentFacts: Array(recent),
            entityCount: store.allEntities().count,
            factCount: facts.count
        )
    }
}
