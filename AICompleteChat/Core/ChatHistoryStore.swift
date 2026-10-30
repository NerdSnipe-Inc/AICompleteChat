import Foundation
import SwiftData
import os

/// One turn in a persisted conversation. Codable, not a `@Model` — stored as JSON inside
/// `ChatRecord.messagesData`, mirroring Alric's proven pattern (`alric/Core/AlricModels.swift`).
struct StoredMessage: Codable, Equatable {
    var role: String
    var content: String
}

/// A persisted conversation. `id` is a plain stored `UUID`, not SwiftData's own
/// `PersistentIdentifier` — per this app's own CLAUDE.md, `PersistentIdentifier` mutates after a
/// context save, which breaks lookups keyed off it.
@Model
final class ChatRecord {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    private var messagesData: Data?

    var storedMessages: [StoredMessage] {
        get {
            guard let messagesData else { return [] }
            do {
                return try JSONDecoder().decode([StoredMessage].self, from: messagesData)
            } catch {
                // A chat that decodes to [] looks empty to the user — make the corruption visible.
                Logger(subsystem: "cc.nerdsnipe.AICompleteChat", category: "ChatHistoryStore")
                    .error("Stored messages for chat \(self.id) are undecodable: \(String(describing: error), privacy: .public)")
                return []
            }
        }
        set {
            do {
                messagesData = try JSONEncoder().encode(newValue)
            } catch {
                Logger(subsystem: "cc.nerdsnipe.AICompleteChat", category: "ChatHistoryStore")
                    .error("Could not encode messages for chat \(self.id); keeping previous data: \(String(describing: error), privacy: .public)")
            }
        }
    }

    init(id: UUID = UUID(), title: String, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// `@MainActor` wrapper around chat history's own `ModelContainer` — same self-contained pattern
/// `MemoryGraphStore` uses (own container, own on-disk file under Application Support), so chat
/// history persists across launches without threading a `ModelContext` through the view hierarchy.
@MainActor
final class ChatHistoryStore {
    private let container: ModelContainer
    private var context: ModelContext { container.mainContext }
    private let logger = Logger(subsystem: "com.nerdsnipe.aicompletechat", category: "ChatHistoryStore")

    init(inMemory: Bool = false) {
        let schema = Schema([ChatRecord.self])
        do {
            let configuration = inMemory
                ? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                : ModelConfiguration(schema: schema, url: Self.onDiskStoreURL())
            container = try ModelContainer(for: schema, configurations: configuration)
        } catch {
            logger.error("Chat history container failed, falling back to in-memory: \(error.localizedDescription)")
            container = try! ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            )
        }
    }

    /// Namespaced under our own bundle identifier rather than the shared Application Support
    /// root — this app has no App Sandbox entitlement, so `.applicationSupportDirectory` resolves
    /// to the real, shared `~/Library/Application Support`, the same folder every other
    /// unsandboxed app on the Mac uses; a bare filename there sits directly alongside everyone
    /// else's data with no isolation.
    private static func onDiskStoreURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let hostDirectory = appSupport.appendingPathComponent("com.nerdsnipe.aicompletechat", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: hostDirectory, withIntermediateDirectories: true)
        } catch {
            Logger(subsystem: "cc.nerdsnipe.AICompleteChat", category: "ChatHistoryStore")
                .error("cannot create history directory: \(error.localizedDescription, privacy: .public)")
        }
        let newURL = hostDirectory.appendingPathComponent("AICompleteChatHistory.store")
        migrateFromUnnamespacedLocation(appSupport: appSupport, to: newURL)
        return newURL
    }

    /// One-time migration for installs that already have data at the old, unnamespaced path
    /// (`Application Support/AICompleteChatHistory.store`) — moves the SQLite file and its
    /// `-shm`/`-wal` siblings so real existing chat history isn't silently orphaned by the
    /// namespacing fix. No-ops once the new location exists or the old one doesn't.
    private static func migrateFromUnnamespacedLocation(appSupport: URL, to newURL: URL) {
        let oldURL = appSupport.appendingPathComponent("AICompleteChatHistory.store")
        guard !FileManager.default.fileExists(atPath: newURL.path),
              FileManager.default.fileExists(atPath: oldURL.path)
        else { return }
        for suffix in ["", "-shm", "-wal"] {
            let source = URL(fileURLWithPath: oldURL.path + suffix)
            let destination = URL(fileURLWithPath: newURL.path + suffix)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            do { try FileManager.default.moveItem(at: source, to: destination) } catch {
                Logger(subsystem: "cc.nerdsnipe.AICompleteChat", category: "ChatHistoryStore")
                    .error("legacy history migration failed for \(source.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func persist() {
        do { try context.save() } catch {
            logger.error("saving chat history failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// All persisted chats, most recently updated first.
    func allChats() -> [ChatRecord] {
        let descriptor = FetchDescriptor<ChatRecord>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        do { return try context.fetch(descriptor) } catch {
            logger.error("fetching chats failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    @discardableResult
    func createChat() -> ChatRecord {
        let chat = ChatRecord(title: "New Chat")
        context.insert(chat)
        persist()
        return chat
    }

    func chat(id: UUID) -> ChatRecord? {
        allChats().first { $0.id == id }
    }

    /// Saves the given messages onto the chat with `id`, deriving a title from the first user
    /// message on first save. No-ops on empty `messages` — an untouched new chat isn't persisted.
    /// No-ops when `messages` matches what's already stored too — merely switching to and back
    /// off of a chat (with nothing said) must not bump `updatedAt`, or selecting any chat in the
    /// sidebar reorders the list and stamps the chat you left as "just now".
    /// Returns whether anything was actually written.
    @discardableResult
    func save(id: UUID, messages: [StoredMessage]) -> Bool {
        guard !messages.isEmpty, let chat = chat(id: id), chat.storedMessages != messages else { return false }
        chat.storedMessages = messages
        chat.updatedAt = Date()
        if chat.title == "New Chat", let firstUserText = messages.first(where: { $0.role == "user" })?.content {
            chat.title = String(firstUserText.prefix(48))
        }
        persist()
        return true
    }

    func delete(id: UUID) {
        guard let chat = chat(id: id) else { return }
        context.delete(chat)
        persist()
    }
}
