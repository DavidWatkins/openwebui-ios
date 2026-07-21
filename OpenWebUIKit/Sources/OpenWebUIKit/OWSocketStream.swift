import Foundation

/// Streaming updates from the socket flow. Unlike SSE (`OWStreamUpdate`), the
/// content is CUMULATIVE — Open WebUI resends the full text each tick — so
/// `.content` should REPLACE the assistant message, not append.
public enum OWSocketUpdate: Sendable {
    case content(String)   // full assistant text so far
    case status(String)    // tool-progress description (e.g. "🔧 weather: Boston")
    case done
    case error(String)
}

extension OpenWebUIClient {
    /// Lazily connect (and `user-join`) the shared socket. Reuses a live one;
    /// reconnects if a previous socket died (e.g. after backgrounding).
    private func ensureSocket() async throws -> OWSocket {
        if let socket, await socket.isConnected { return socket }
        await socket?.disconnect()
        guard let token else { throw OWError.notAuthenticated }
        let s = OWSocket(base: config.baseURL, token: token)
        try await s.connect()
        socket = s
        return s
    }

    /// True token streaming for a server chat via the socket flow. The chat +
    /// assistant message must already exist server-side (create/update first) so
    /// `chatID`/`messageID` route the events. `.content` values are cumulative.
    public func socketStream(chatID: String, messageID: String, model: String,
                             messages: [OWChatMessageInput], files: [OWAttachment] = [],
                             options: OWStreamOptions = OWStreamOptions()) -> AsyncStream<OWSocketUpdate> {
        AsyncStream { continuation in
            let work = Task {
                do {
                    let sock = try await ensureSocket()
                    await sock.setOnEvent { ev in
                        guard ev.messageID == messageID else { return }
                        switch ev.type {
                        case "chat:completion":
                            if let t = ev.text, !t.isEmpty { continuation.yield(.content(t)) }
                            if ev.done { continuation.yield(.done); continuation.finish() }
                        case "status":
                            if let s = ev.statusText { continuation.yield(.status(s)) }
                        case "chat:active":
                            if ev.done { continuation.yield(.done); continuation.finish() }
                        default:
                            break
                        }
                    }
                    let sid = await sock.sid ?? ""
                    try await postSocketCompletion(chatID: chatID, messageID: messageID,
                                                   sessionID: sid, model: model,
                                                   messages: messages, files: files, options: options)
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.yield(.error((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    /// Kicks off the background completion bound to `chatID`/`session_id`; the
    /// response streams back over the socket, not this HTTP response.
    private func postSocketCompletion(chatID: String, messageID: String, sessionID: String,
                                      model: String, messages: [OWChatMessageInput],
                                      files: [OWAttachment], options: OWStreamOptions) async throws {
        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "chat_id": chatID,
            "id": messageID,
            "session_id": sessionID,
            "messages": messages.map { msg -> [String: Any] in
                // Multimodal: keep images so vision works over the socket path too.
                if msg.imageURLs.isEmpty { return ["role": msg.role, "content": msg.text] }
                var parts: [[String: Any]] = []
                if !msg.text.isEmpty { parts.append(["type": "text", "text": msg.text]) }
                for u in msg.imageURLs { parts.append(["type": "image_url", "image_url": ["url": u]]) }
                return ["role": msg.role, "content": parts]
            },
        ]
        if !files.isEmpty {
            body["files"] = files.map { ["type": $0.type, "id": $0.id as Any].compactMapValues { $0 } }
        }
        var features: [String: Any] = [:]
        if options.webSearch { features["web_search"] = true }
        if options.imageGeneration { features["image_generation"] = true }
        if options.codeInterpreter { features["code_interpreter"] = true }
        if !features.isEmpty { body["features"] = features }
        if !options.toolIDs.isEmpty { body["tool_ids"] = options.toolIDs }

        var req = request("/api/chat/completions", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await send(req)   // returns {status, task_ids}; the stream is on the socket
    }

    /// Drop the socket (e.g. on logout or when backgrounding for a long time).
    public func closeSocket() async {
        await socket?.disconnect()
        socket = nil
    }
}
