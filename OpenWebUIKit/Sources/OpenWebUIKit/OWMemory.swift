import Foundation

/// A durable fact Open WebUI stores about the user (its "Memory" feature). We
/// extract these from conversations and inject the relevant ones back into
/// context, so the assistant remembers you across chats (ChatGPT-style).
public struct OWMemory: Decodable, Identifiable, Sendable, Hashable {
    public var id: String
    public var content: String
    public var createdAt: Double?

    enum CodingKeys: String, CodingKey { case id, content, created_at }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        content = (try? c.decode(String.self, forKey: .content)) ?? ""
        createdAt = try? c.decode(Double.self, forKey: .created_at)
    }
    public init(id: String, content: String, createdAt: Double? = nil) {
        self.id = id; self.content = content; self.createdAt = createdAt
    }
}

extension OpenWebUIClient {
    /// GET /api/v1/memories/ — all of the user's stored memories.
    public func memories() async throws -> [OWMemory] {
        decodeList(OWMemory.self, try await send(request("/api/v1/memories/")))
    }

    /// POST /api/v1/memories/add — store a new memory.
    @discardableResult
    public func addMemory(_ content: String) async throws -> OWMemory {
        let req = try jsonRequest("/api/v1/memories/add", method: "POST", body: ["content": content])
        return try decode(OWMemory.self, try await send(req))
    }

    /// POST /api/v1/memories/query — semantic search; returns the matching texts.
    public func queryMemories(_ text: String, limit: Int = 6) async throws -> [String] {
        let req = try jsonRequest("/api/v1/memories/query", method: "POST", body: ["content": text])
        struct R: Decodable { var documents: [[String]]? }
        let r = try decode(R.self, try await send(req))
        return Array((r.documents?.first ?? []).prefix(limit))
    }

    public func deleteMemory(_ id: String) async throws {
        _ = try await send(request("/api/v1/memories/\(encPath(id))", method: "DELETE"))
    }

    /// Ask a base model to pull NEW durable user-facts from one exchange, skipping
    /// anything already known. Returns the new facts (possibly empty); best-effort,
    /// never throws. `model` should be a base model, not the Agent pipe.
    public func extractMemories(model: String, userText: String, replyText: String,
                                existing: [String]) async -> [String] {
        let known = existing.isEmpty ? "(none yet)" : existing.map { "- \($0)" }.joined(separator: "\n")
        let system = """
        You maintain a long-term memory of durable facts about the USER — their \
        identity, stable preferences, ongoing projects, constraints, recurring \
        context. From the exchange, extract only NEW such facts not already known. \
        Ignore transient/one-off details, questions, and anything about the assistant. \
        Output ONLY a JSON array of short factual strings (e.g. ["Prefers concise \
        answers","Building an iOS app"]) — or [] if there's nothing worth keeping.
        """
        let user = """
        Already known:
        \(known)

        Exchange:
        User: \(userText.prefix(1500))
        Assistant: \(replyText.prefix(1500))
        """
        guard let raw = await oneShotCompletion(model: model, system: system, user: user) else { return [] }
        // Pull the first JSON array out of the reply and decode it.
        guard let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]"), start <= end else { return [] }
        let json = String(raw[start...end])
        guard let arr = try? JSONDecoder().decode([String].self, from: Data(json.utf8)) else { return [] }
        return arr.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 200 }
    }
}
