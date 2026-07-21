import Foundation

/// Minimal Engine.IO v4 / Socket.IO v4 client over `URLSessionWebSocketTask`
/// (Foundation only — keeps OpenWebUIKit dependency-free). Speaks just enough of
/// the protocol for Open WebUI's real-time chat flow:
///   connect → `user-join` (JWT) → receive `events` for the active chat.
///
/// Protocol reference (verified against Open WebUI 0.10.2):
///   - Engine.IO packets are a single ASCII digit + payload: `0`=open, `2`=ping,
///     `3`=pong, `4`=message. Socket.IO rides inside `4` messages: `40`=connect,
///     `42`=event `["name", data]`, `43`=ack `<id>[response]`.
///   - After connect we emit `user-join {auth:{token}}` (needs the login JWT) and
///     the server routes chat `events` to our session id.
public actor OWSocket {
    /// A pre-parsed chat event (fully Sendable — parsing happens in the Kit).
    public struct Event: Sendable {
        public let chatID: String
        public let messageID: String
        /// The inner `data.type`: "status", "chat:completion", "chat:active", …
        public let type: String
        /// For `chat:completion` — the assistant's CUMULATIVE output text so far
        /// (Open WebUI sends the full text each tick, so replace, don't append).
        public let text: String?
        /// For `chat:completion` — the CUMULATIVE reasoning/thinking text (from the
        /// `reasoning` output block), kept separate so it doesn't leak into the reply.
        public let reasoning: String?
        /// For `status` — the tool-progress description (e.g. "🔧 weather: Boston").
        public let statusText: String?
        /// True on the final `chat:completion` (`done`) or a `chat:active:false`.
        public let done: Bool
    }

    private let base: URL
    private let token: String
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pingTimer: Task<Void, Never>?
    private var ackID = 0
    private var acks: [Int: CheckedContinuation<[String: Any], Never>] = [:]

    /// Server-assigned Engine.IO session id (also the chat `session_id`). nil until connected.
    public private(set) var sid: String?
    /// Whether the websocket is still live (drops after backgrounding / network loss).
    public var isConnected: Bool { task?.state == .running && sid != nil }
    /// Fired for every routed `events` message. Set before `connect()`.
    public var onEvent: (@Sendable (Event) -> Void)?

    public init(base: URL, token: String) {
        self.base = base
        self.token = token
    }

    public func setOnEvent(_ handler: @escaping @Sendable (Event) -> Void) { onEvent = handler }

    // MARK: - Connection

    /// Opens the websocket, completes the Engine.IO/Socket.IO handshake, and
    /// registers the session with `user-join`. Throws on handshake failure.
    public func connect() async throws {
        guard var comps = URLComponents(url: base.appendingPathComponent("/ws/socket.io/"),
                                        resolvingAgainstBaseURL: false) else { throw OWError.transport("bad socket URL") }
        comps.scheme = (comps.scheme == "https") ? "wss" : "ws"
        comps.queryItems = [.init(name: "EIO", value: "4"), .init(name: "transport", value: "websocket")]
        guard let url = comps.url else { throw OWError.transport("bad socket URL") }

        let cfg = URLSessionConfiguration.default
        let session = URLSession(configuration: cfg)
        self.session = session
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()

        // Engine.IO open packet: "0{...json...}"
        let open = try await receiveText()
        guard open.first == "0" else { throw OWError.transport("unexpected socket open packet") }
        // Socket.IO connect
        try await send("40")
        // Consume the Socket.IO connect ack ("40{\"sid\":...}") and grab our sid.
        let connectAck = try await receiveText()
        sid = Self.extractSID(connectAck)

        startPingLoop()
        startReceiveLoop()

        // Register with the user (routes chat events to our session).
        _ = await emitWithAck("user-join", ["auth": ["token": token]])
    }

    public func disconnect() {
        pingTimer?.cancel(); pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel(); session = nil
        for (_, c) in acks { c.resume(returning: [:]) }
        acks.removeAll()
    }

    // MARK: - Emit

    /// Emit an event and await the server's ack payload (used for `user-join`).
    @discardableResult
    public func emitWithAck(_ event: String, _ payload: [String: Any]) async -> [String: Any] {
        ackID += 1
        let id = ackID
        let arr: [Any] = [event, payload]
        guard let json = try? JSONSerialization.data(withJSONObject: arr),
              let body = String(data: json, encoding: .utf8) else { return [:] }
        return await withCheckedContinuation { cont in
            acks[id] = cont
            Task { try? await send("42\(id)\(body)") }
        }
    }

    public func emit(_ event: String, _ payload: [String: Any]) async {
        let arr: [Any] = [event, payload]
        guard let json = try? JSONSerialization.data(withJSONObject: arr),
              let body = String(data: json, encoding: .utf8) else { return }
        try? await send("42\(body)")
    }

    // MARK: - Receive loop

    private func startReceiveLoop() {
        Task { await self.receiveLoop() }
    }

    private func receiveLoop() async {
        while let t = task, t.state == .running {
            guard let text = try? await receiveText() else { break }
            handle(text)
        }
    }

    private func handle(_ text: String) {
        guard let first = text.first else { return }
        switch first {
        case "2":                      // Engine.IO ping → pong
            Task { try? await send("3") }
        case "4":                      // Socket.IO message
            let body = String(text.dropFirst())   // drop the Engine.IO "4"
            handleSocketIO(body)
        default:
            break
        }
    }

    private func handleSocketIO(_ body: String) {
        guard let kind = body.first else { return }
        switch kind {
        case "2":  // event: 42[...]  (may have an ack id we ignore for server->client)
            let rest = String(body.dropFirst())
            let json = rest.drop { $0.isNumber }   // skip any leading ack id
            decodeEvent(String(json))
        case "3":  // ack: 43<id>[response]
            let rest = body.dropFirst()
            let idStr = String(rest.prefix { $0.isNumber })
            let json = String(rest.drop { $0.isNumber })
            if let id = Int(idStr), let cont = acks.removeValue(forKey: id) {
                let arr = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [Any]
                cont.resume(returning: (arr?.first as? [String: Any]) ?? [:])
            }
        default:
            break
        }
    }

    private func decodeEvent(_ json: String) {
        guard let arr = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [Any],
              arr.count >= 2, (arr[0] as? String) == "events",
              let payload = arr[1] as? [String: Any] else { return }
        let inner = payload["data"] as? [String: Any] ?? [:]
        let type = inner["type"] as? String ?? ""
        let data = inner["data"] as? [String: Any] ?? [:]

        var text: String?
        var reasoning: String?
        var statusText: String?
        var done = false
        switch type {
        case "chat:completion":
            // `data.output` is an array of typed blocks. A `reasoning` block holds
            // the model's thinking (start_tag "<think>"); a `message` block holds
            // the answer. Both carry text at content[].output_text and are
            // CUMULATIVE. Keep them apart so thinking never leaks into the reply.
            if let output = data["output"] as? [[String: Any]] {
                var answer = "", think = ""
                for block in output {
                    let joined = (block["content"] as? [[String: Any]])?
                        .compactMap { ($0["type"] as? String) == "output_text" ? $0["text"] as? String : nil }
                        .joined() ?? ""
                    if (block["type"] as? String) == "reasoning" { think += joined }
                    else { answer += joined }
                }
                if !answer.isEmpty { text = answer }
                if !think.isEmpty { reasoning = think }
            }
            done = (data["done"] as? Bool) ?? false
        case "status":
            statusText = data["description"] as? String
            done = (data["done"] as? Bool) ?? false
        case "chat:active":
            done = ((data["active"] as? Bool) == false)
        default:
            break
        }
        onEvent?(Event(chatID: payload["chat_id"] as? String ?? "",
                       messageID: payload["message_id"] as? String ?? "",
                       type: type, text: text, reasoning: reasoning,
                       statusText: statusText, done: done))
    }

    // MARK: - Low-level

    private func send(_ text: String) async throws {
        guard let task else { throw OWError.transport("socket not connected") }
        try await task.send(.string(text))
    }

    private func receiveText() async throws -> String {
        guard let task else { throw OWError.transport("socket not connected") }
        switch try await task.receive() {
        case .string(let s): return s
        case .data(let d):   return String(decoding: d, as: UTF8.self)
        @unknown default:    return ""
        }
    }

    private func startPingLoop() {
        // Engine.IO servers also ping us; we additionally send a heartbeat so idle
        // connections stay alive through NAT/proxies.
        pingTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25 * 1_000_000_000)
                await self?.sendPing()
            }
        }
    }
    private func sendPing() async { try? await send("2") }

    private static func extractSID(_ packet: String) -> String? {
        // "40{\"sid\":\"...\"}"
        guard let brace = packet.firstIndex(of: "{") else { return nil }
        let json = String(packet[brace...])
        let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        return obj?["sid"] as? String
    }
}
