import Testing
import AiPersona
@testable import AICompleteChat

@MainActor
@Suite("MemorySnapshotProvider")
struct MemorySnapshotProviderTests {
    @Test("empty store produces empty snapshot")
    func emptyStoreProducesEmptySnapshot() {
        let store = MemoryGraphStore(inMemory: true)
        let snapshot = MemorySnapshotProvider.snapshot(from: store, limit: 5)
        #expect(snapshot.factCount == 0)
        #expect(snapshot.entityCount == 0)
        #expect(snapshot.recentFacts.isEmpty)
    }

    @Test("populated store reports counts and recent facts")
    func populatedStoreReportsCounts() {
        let store = MemoryGraphStore(inMemory: true)
        let subject = store.upsertEntity(name: "Daniel", summary: "Daniel", kind: .user, embedding: [])
        store.addFact(subjectID: subject.id, objectID: nil, predicate: "prefers", factText: "Daniel prefers dark mode", embedding: [])

        let snapshot = MemorySnapshotProvider.snapshot(from: store, limit: 5)
        #expect(snapshot.factCount == 1)
        #expect(snapshot.entityCount == 1)
        #expect(snapshot.recentFacts == ["Daniel prefers dark mode"])
    }
}
