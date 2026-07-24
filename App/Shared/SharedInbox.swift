import Foundation

/// Content handed from the Share Extension to the main app through the shared
/// App Group container. Text/URL travel in UserDefaults; files are copied into
/// the container and referenced by name.
public struct SharedItem: Codable, Equatable {
    public enum Kind: String, Codable { case url, text, file }
    public var kind: Kind
    public var text: String?       // URL string (`.url`) or raw text (`.text`)
    public var fileName: String?   // relative name in the container (`.file`)
    public var displayName: String?
    public var mime: String?

    public init(kind: Kind, text: String? = nil, fileName: String? = nil,
                displayName: String? = nil, mime: String? = nil) {
        self.kind = kind; self.text = text; self.fileName = fileName
        self.displayName = displayName; self.mime = mime
    }
}

/// The drop box between the Share Extension and the app. Both targets link this
/// file. If the App Group isn't provisioned the accessors no-op (return nil),
/// so a misconfiguration degrades to "sharing doesn't arrive", never a crash.
public enum SharedInbox {
    /// Must match the `com.apple.security.application-groups` entitlement on both
    /// the app and the extension.
    public static let groupID = "group.com.example.openwebui"
    private static let key = "pendingShare"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: groupID) }
    private static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    public static func write(_ item: SharedItem) {
        guard let data = try? JSONEncoder().encode(item) else { return }
        defaults?.set(data, forKey: key)
    }

    /// Read and clear the pending item (single delivery).
    public static func take() -> SharedItem? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        defaults?.removeObject(forKey: key)
        return try? JSONDecoder().decode(SharedItem.self, from: data)
    }

    public static var hasPending: Bool { defaults?.data(forKey: key) != nil }

    // MARK: - File payloads

    @discardableResult
    public static func writeFile(_ data: Data, name: String) -> String? {
        guard let url = container?.appendingPathComponent(name) else { return nil }
        do { try data.write(to: url); return name } catch { return nil }
    }

    public static func readFile(_ name: String) -> Data? {
        guard let url = container?.appendingPathComponent(name) else { return nil }
        return try? Data(contentsOf: url)
    }

    public static func removeFile(_ name: String) {
        guard let url = container?.appendingPathComponent(name) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
