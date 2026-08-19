import Foundation

/// A snapshot of the memory store at a point in time.
/// Task 2 definition — used by Memory Inspector panel (Task 9).
struct MemorySnapshot: Equatable {
    /// Recent facts from the store (limited by caller's `limit` parameter).
    let recentFacts: [String]
    /// Total entity count in the store.
    let entityCount: Int
    /// Total fact count in the store.
    let factCount: Int
}
