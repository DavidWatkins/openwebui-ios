import SwiftUI
import SwiftData
import OpenWebUIKit

/// Loads and mutates the user's chat list from Open WebUI.
@MainActor
final class ChatStore: ObservableObject {
    @Published var chats: [OWChatSummary] = []
    @Published var loading = false
    @Published var error: String?
    /// Full-text search results (title + message content). Populated by `search`.
    @Published var searchResults: [OWChatSummary] = []

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
            localStore.cacheSummaries(server)   // keep the offline list fresh
            chats = sorted(local + server)
            error = nil
        } catch is CancellationError {
        } catch {
            // Server down: show local chats plus any cached server chats we've
            // opened before, so past conversations stay readable offline.
            chats = sorted(local + localStore.cachedSummaries())
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Full-text search: server-side (all chats, with snippets) when reachable,
    /// merged with local device/cached matches; local-only when offline.
    func search(_ text: String) async {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { searchResults = []; return }
        let local = localStore.search(q)
        var merged = local
        if let server = try? await client.searchChats(q) {
            if Task.isCancelled { return }
            let serverIDs = Set(server.map(\.id))
            merged = server + local.filter { !serverIDs.contains($0.id) }
        }
        if Task.isCancelled { return }
        searchResults = merged
    }

    func delete(_ chat: OWChatSummary) async {
        if chat.isLocal {
            localStore.delete(id: chat.id)
            chats.removeAll { $0.id == chat.id }
            return
        }
        do {
            try await client.deleteChat(chat.id)
            localStore.deleteCached(id: chat.id)
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

/// On-device cache of a SERVER chat, so past conversations are readable with no
/// connectivity. Distinct from `LocalChat` (device-only chats that never sync):
/// these mirror real server chats, refreshed whenever the server is reachable.
/// The full branching tree is stored so offline reads keep edit/regenerate history.
@Model
final class CachedServerChat {
    @Attribute(.unique) var id: String
    var title: String
    var createdAt: Double
    var updatedAt: Double
    var pinned: Bool
    var archived: Bool
    var currentId: String?
    private var modelsData: Data
    private var treeData: Data

    var models: [String] {
        get { (try? JSONDecoder().decode([String].self, from: modelsData)) ?? [] }
        set { modelsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
    /// Every node in the branching history (not just the active branch).
    var tree: [OWMessage] {
        get { (try? JSONDecoder().decode([OWMessage].self, from: treeData)) ?? [] }
        set { treeData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
    var hasHistory: Bool { !treeData.isEmpty && !tree.isEmpty }

    init(id: String, title: String, createdAt: Double, updatedAt: Double,
         pinned: Bool, archived: Bool, currentId: String?, models: [String], tree: [OWMessage]) {
        self.id = id; self.title = title; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.pinned = pinned; self.archived = archived; self.currentId = currentId
        self.modelsData = (try? JSONEncoder().encode(models)) ?? Data()
        self.treeData = (try? JSONEncoder().encode(tree)) ?? Data()
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
        // storage failure degrades to "chats don't persist" rather than a
        // launch crash.
        if let c = try? ModelContainer(for: LocalChat.self, CachedServerChat.self) {
            container = c
        } else {
            let cfg = ModelConfiguration(isStoredInMemoryOnly: true)
            container = try! ModelContainer(for: LocalChat.self, CachedServerChat.self, configurations: cfg)
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

    // MARK: - Server chat cache (offline read)

    private func cached(id: String) -> CachedServerChat? {
        let d = FetchDescriptor<CachedServerChat>(predicate: #Predicate { $0.id == id })
        return try? ctx.fetch(d).first ?? nil
    }

    /// Refresh cached list metadata from a server fetch (keeps any cached history).
    func cacheSummaries(_ list: [OWChatSummary]) {
        for s in list {
            if let e = cached(id: s.id) {
                e.title = s.title
                if let u = s.updatedAt { e.updatedAt = u }
                if let c = s.createdAt { e.createdAt = c }
                e.pinned = s.pinned; e.archived = s.archived
            } else {
                ctx.insert(CachedServerChat(id: s.id, title: s.title,
                    createdAt: s.createdAt ?? 0, updatedAt: s.updatedAt ?? 0,
                    pinned: s.pinned, archived: s.archived, currentId: nil, models: [], tree: []))
            }
        }
        try? ctx.save()
    }

    /// Cached server chats that actually have history (i.e. were opened) — the set
    /// that's genuinely readable offline, newest first.
    func cachedSummaries() -> [OWChatSummary] {
        let d = FetchDescriptor<CachedServerChat>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        return ((try? ctx.fetch(d)) ?? []).filter(\.hasHistory).map {
            OWChatSummary(id: $0.id, title: $0.title, updatedAt: $0.updatedAt,
                          createdAt: $0.createdAt, pinned: $0.pinned, archived: $0.archived, isLocal: false)
        }
    }

    /// Store a chat's full history tree for offline reading.
    func cacheChat(_ chat: OWChat) {
        guard !chat.id.isEmpty else { return }
        let nodes = chat.allMessages.isEmpty ? chat.messages : chat.allMessages
        guard !nodes.isEmpty else { return }
        if let e = cached(id: chat.id) {
            if !chat.title.isEmpty { e.title = chat.title }
            e.models = chat.models
            e.tree = nodes
            e.currentId = chat.currentId
        } else {
            let now = Date().timeIntervalSince1970
            ctx.insert(CachedServerChat(id: chat.id, title: chat.title,
                createdAt: now, updatedAt: now, pinned: false, archived: false,
                currentId: chat.currentId, models: chat.models, tree: nodes))
        }
        try? ctx.save()
    }

    /// Reconstruct a cached server chat for offline reading (nil if none cached).
    func cachedChat(id: String) -> OWChat? {
        guard let e = cached(id: id), e.hasHistory else { return nil }
        return OWChat(id: e.id, title: e.title, models: e.models,
                      allMessages: e.tree, currentId: e.currentId)
    }

    func deleteCached(id: String) {
        guard let e = cached(id: id) else { return }
        ctx.delete(e); try? ctx.save()
    }

    // MARK: - Local full-text search (offline / device chats)

    /// Full-text search over on-device local chats + cached server chats. Matches
    /// title or any message body; returns summaries with a matching `snippet`.
    func search(_ text: String) -> [OWChatSummary] {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        var out: [OWChatSummary] = []
        for c in all() {
            if let snip = Self.match(title: c.title, bodies: c.messages.map(\.content), query: q) {
                out.append(OWChatSummary(id: c.id, title: c.title, updatedAt: c.updatedAt,
                    createdAt: c.createdAt, pinned: false, archived: false, isLocal: true, snippet: snip))
            }
        }
        let d = FetchDescriptor<CachedServerChat>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        for c in (try? ctx.fetch(d)) ?? [] where c.hasHistory {
            if let snip = Self.match(title: c.title, bodies: c.tree.map(\.content), query: q) {
                out.append(OWChatSummary(id: c.id, title: c.title, updatedAt: c.updatedAt,
                    createdAt: c.createdAt, pinned: c.pinned, archived: c.archived, isLocal: false, snippet: snip))
            }
        }
        return out
    }

    /// Returns a short excerpt around the first body match (or the title itself if
    /// only the title matched), or nil when nothing matches.
    private static func match(title: String, bodies: [String], query: String) -> String? {
        for body in bodies {
            let lower = body.lowercased()
            if let r = lower.range(of: query) {
                let start = body.index(r.lowerBound, offsetBy: -40, limitedBy: body.startIndex) ?? body.startIndex
                let end = body.index(r.upperBound, offsetBy: 60, limitedBy: body.endIndex) ?? body.endIndex
                let excerpt = body[start..<end].replacingOccurrences(of: "\n", with: " ")
                return (start > body.startIndex ? "…" : "") + excerpt + (end < body.endIndex ? "…" : "")
            }
        }
        return title.lowercased().contains(query) ? title : nil
    }
}
