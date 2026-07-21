import SwiftUI
import SwiftData
import OpenWebUIKit

/// Loads and mutates the user's chat list from Open WebUI.
@MainActor
final class ChatStore: ObservableObject {
    @Published var chats: [OWChatSummary] = []
    @Published var loading = false
    @Published var error: String?

    private let client: OpenWebUIClient
    private let localStore: LocalChatStore
    init(client: OpenWebUIClient, localStore: LocalChatStore) {
        self.client = client
        self.localStore = localStore
    }

    /// Sort: pinned first, then most-recently-updated.
    private func sorted(_ list: [OWChatSummary]) -> [OWChatSummary] {
        list.filter { !$0.archived }.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned && !rhs.pinned }
            return (lhs.updatedAt ?? 0) > (rhs.updatedAt ?? 0)
        }
    }

    func load() async {
        loading = true
        defer { loading = false }
        // On-device chats always show — even if the server is unreachable.
        let local = localStore.summaries()
        do {
            // The main list excludes pinned chats, so fetch those separately and
            // merge. Pinned fetch is best-effort: a failure must not wipe the list.
            let regular = try await client.chats()
            let pinned: [OWChatSummary] = (try? await client.pinnedChats())?
                .map { var c = $0; c.pinned = true; return c } ?? []
            let pinnedIDs = Set(pinned.map(\.id))
            let server = pinned + regular.filter { !pinnedIDs.contains($0.id) }
            chats = sorted(local + server)
            error = nil
        } catch is CancellationError {
        } catch {
            // Server down: still show local chats so on-device history stays usable.
            chats = sorted(local)
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func delete(_ chat: OWChatSummary) async {
        if chat.isLocal {
            localStore.delete(id: chat.id)
            chats.removeAll { $0.id == chat.id }
            return
        }
        do {
            try await client.deleteChat(chat.id)
            chats.removeAll { $0.id == chat.id }
        } catch { report(error) }
    }

    // Server-only actions (pin / archive / clone / share / export) are no-ops for
    // on-device chats — they have no server record to act on.
    func pin(_ chat: OWChatSummary) async {
        guard !chat.isLocal else { return }
        do { try await client.pinChat(chat.id); await load() } catch { report(error) }
    }

    func archive(_ chat: OWChatSummary) async {
        guard !chat.isLocal else { return }
        do { try await client.archiveChat(chat.id); chats.removeAll { $0.id == chat.id } }
        catch { report(error) }
    }

    func clone(_ chat: OWChatSummary) async {
        guard !chat.isLocal else { return }
        do { _ = try await client.cloneChat(chat.id); await load() } catch { report(error) }
    }

    func rename(_ chat: OWChatSummary, to title: String) async {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if chat.isLocal {
            // Rename in place on-device (preserve its messages/model).
            localStore.save(id: chat.id, title: t,
                            modelID: localStore.chat(id: chat.id)?.modelID,
                            messages: localStore.messages(id: chat.id))
            await load()
            return
        }
        do { try await client.renameChat(chat.id, to: t); await load() } catch { report(error) }
    }

    /// Returns the public share URL for the iOS share sheet.
    func shareLink(_ chat: OWChatSummary) async -> URL? {
        guard !chat.isLocal else { return nil }   // on-device chats can't be shared server-side
        do { return try await client.shareChat(chat.id) } catch { report(error); return nil }
    }

    /// Revokes the public share link (best-effort — a not-shared chat is a no-op).
    func unshare(_ chat: OWChatSummary) async {
        guard !chat.isLocal else { return }
        do { try await client.unshareChat(chat.id) } catch { report(error) }
    }

    /// Exports the chat JSON to a temp file and returns its URL (for "download").
    func export(_ chat: OWChatSummary) async -> URL? {
        guard !chat.isLocal else { return nil }
        do {
            let data = try await client.exportChat(chat.id)
            let safe = chat.title.replacingOccurrences(of: "/", with: "-").prefix(40)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe).json")
            try data.write(to: url)
            return url
        } catch { report(error); return nil }
    }

    private func report(_ error: Error) {
        self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

// MARK: - On-device chat storage
//
// Kept in this file (rather than its own) so it's part of the existing target
// membership without a project regeneration — same reason `DefaultModelPickerView`
// lives in `SettingsView.swift`.

/// Where a chat's history lives.
enum ChatMode: String, CaseIterable, Codable, Sendable {
    case server      // saved to Open WebUI (the account's database) — the default
    case local       // saved on THIS device only (SwiftData); never sent to the server
    case temporary   // ephemeral (ghost): nothing is saved anywhere

    var label: String {
        switch self {
        case .server:    return L("Normal (servidor)")
        case .local:     return L("Somente neste aparelho")
        case .temporary: return L("Temporária (fantasma)")
        }
    }

    /// SF Symbol used in the composer/title and the chat-list badge.
    var symbol: String {
        switch self {
        case .server:    return "cloud"
        case .local:     return "iphone"
        case .temporary: return "clock.badge.xmark"
        }
    }
}

/// One conversation persisted on-device only. Messages are stored as an encoded
/// `[OWMessage]` blob (they're already `Codable`) rather than a relationship, so
/// the schema stays a single table and round-trips through the same model the
/// rest of the app uses.
@Model
final class LocalChat {
    @Attribute(.unique) var id: String
    var title: String
    var createdAt: Double
    var updatedAt: Double
    var modelID: String?
    private var messagesData: Data

    var messages: [OWMessage] {
        get { (try? JSONDecoder().decode([OWMessage].self, from: messagesData)) ?? [] }
        set { messagesData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    init(id: String, title: String, createdAt: Double, updatedAt: Double,
         modelID: String?, messages: [OWMessage]) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.modelID = modelID
        self.messagesData = (try? JSONEncoder().encode(messages)) ?? Data()
    }
}

/// Thin CRUD wrapper around the on-device SwiftData store. Kept as a manual
/// store (not `@Query`) so it slots into the existing `ChatStore` merge logic.
@MainActor
final class LocalChatStore {
    private let container: ModelContainer
    private var ctx: ModelContext { container.mainContext }

    init() {
        // Fall back to an in-memory store if the on-disk one can't open, so a
        // storage failure degrades to "local chats don't persist" rather than a
        // launch crash.
        if let c = try? ModelContainer(for: LocalChat.self) {
            container = c
        } else {
            let cfg = ModelConfiguration(isStoredInMemoryOnly: true)
            container = try! ModelContainer(for: LocalChat.self, configurations: cfg)
        }
    }

    /// All local chats, newest first.
    func all() -> [LocalChat] {
        let d = FetchDescriptor<LocalChat>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        return (try? ctx.fetch(d)) ?? []
    }

    func chat(id: String) -> LocalChat? {
        let d = FetchDescriptor<LocalChat>(predicate: #Predicate { $0.id == id })
        return try? ctx.fetch(d).first ?? nil
    }

    func messages(id: String) -> [OWMessage] { chat(id: id)?.messages ?? [] }

    /// Create or update a local chat, returning its id (generates one if new).
    @discardableResult
    func save(id: String?, title: String, modelID: String?, messages: [OWMessage]) -> String {
        let now = Date().timeIntervalSince1970
        if let id, let existing = chat(id: id) {
            existing.title = title
            existing.modelID = modelID
            existing.messages = messages
            existing.updatedAt = now
            try? ctx.save()
            return id
        }
        let newID = id ?? UUID().uuidString
        ctx.insert(LocalChat(id: newID, title: title, createdAt: now, updatedAt: now,
                             modelID: modelID, messages: messages))
        try? ctx.save()
        return newID
    }

    func delete(id: String) {
        guard let c = chat(id: id) else { return }
        ctx.delete(c)
        try? ctx.save()
    }

    /// Local chats as list summaries (flagged `isLocal` so the row can badge them).
    func summaries() -> [OWChatSummary] {
        all().map {
            OWChatSummary(id: $0.id, title: $0.title, updatedAt: $0.updatedAt,
                          createdAt: $0.createdAt, pinned: false, archived: false, isLocal: true)
        }
    }
}
