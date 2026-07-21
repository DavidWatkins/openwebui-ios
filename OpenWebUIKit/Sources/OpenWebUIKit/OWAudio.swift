import Foundation

/// A voice exposed by the server's TTS engine (OpenAI, ElevenLabs, local, …).
public struct OWVoice: Decodable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) { self.id = id; self.name = name }

    public init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            id = s; name = s; return
        }
        let c = try decoder.container(keyedBy: K.self)
        let vid = (try? c.decode(String.self, forKey: .id))
            ?? (try? c.decode(String.self, forKey: .voice_id))
            ?? (try? c.decode(String.self, forKey: .name)) ?? UUID().uuidString
        id = vid
        name = (try? c.decode(String.self, forKey: .name)) ?? vid
    }
    enum K: String, CodingKey { case id, voice_id, name }
}

/// What the server's Audio admin config reports for STT/TTS. Decoded best-effort
/// because the exact JSON shape varies across Open WebUI versions.
public struct OWAudioConfig: Sendable, Equatable {
    public var sttEngine: String     // "" = local faster-whisper
    public var sttModel: String?
    public var ttsEngine: String     // "" = local/transformers
    public var ttsModel: String?
    public var ttsVoice: String?

    /// e.g. "faster-whisper (built-in) · base", "openai", "deepgram". An empty
    /// engine is Open WebUI's own bundled whisper, not a remote STT.
    public var sttSummary: String {
        let engine = sttEngine.isEmpty ? "faster-whisper (built-in)" : sttEngine
        if let m = sttModel, !m.isEmpty { return "\(engine) · \(m)" }
        return engine
    }
    /// e.g. "openai · tts-1 · alloy", "elevenlabs". An empty engine is the
    /// unconfigured default slot (no remote TTS wired in).
    public var ttsSummary: String {
        var parts = [ttsEngine.isEmpty ? "default (unconfigured)" : ttsEngine]
        if let m = ttsModel, !m.isEmpty { parts.append(m) }
        if let v = ttsVoice, !v.isEmpty { parts.append(v) }
        return parts.joined(separator: " · ")
    }
}

extension OpenWebUIClient {
    /// Diagnostic: raw GET returning "HTTP <code>\n<body>" (or an error line),
    /// so an unexpected/empty audio response can be inspected from the app.
    public func rawGET(_ path: String) async -> String {
        let req = request(path)
        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes, non-UTF8>"
            return "GET \(path) → HTTP \(code)\n\(body.prefix(1500))"
        } catch {
            return "GET \(path) → \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    /// GET /api/v1/audio/config — the server's configured STT/TTS engines. Admin-
    /// gated and version-dependent, so this is best-effort: returns nil on any
    /// failure (403, missing endpoint, unexpected shape) rather than throwing.
    public func audioConfig() async -> OWAudioConfig? {
        guard let data = try? await send(request("/api/v1/audio/config")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let tts = obj["tts"] as? [String: Any]
        let stt = obj["stt"] as? [String: Any]
        guard tts != nil || stt != nil else { return nil }
        func s(_ d: [String: Any]?, _ keys: [String]) -> String? {
            guard let d else { return nil }
            for k in keys { if let v = d[k] as? String, !v.isEmpty { return v } }
            return nil
        }
        return OWAudioConfig(
            sttEngine: s(stt, ["ENGINE", "engine"]) ?? "",
            sttModel: s(stt, ["WHISPER_MODEL", "MODEL", "model"]),
            ttsEngine: s(tts, ["ENGINE", "engine"]) ?? "",
            ttsModel: s(tts, ["MODEL", "model"]),
            ttsVoice: s(tts, ["VOICE", "voice"])
        )
    }

    /// POST /api/v1/audio/speech — OpenAI-compatible TTS. Returns the synthesized
    /// audio bytes (mp3) from the server's configured engine. Empty `voice`/`model`
    /// are omitted so the server can fall back to its own defaults.
    public func speech(text: String, voice: String = "", model: String = "") async throws -> Data {
        var body: [String: Any] = ["input": text]
        if !model.isEmpty { body["model"] = model }
        if !voice.isEmpty { body["voice"] = voice }
        var req = request("/api/v1/audio/speech", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(req, long: true)
    }

    /// POST /api/v1/audio/transcriptions — server-side STT (Whisper). Uploads the
    /// audio (multipart) and returns the recognized text.
    public func transcribe(audio: Data, filename: String = "speech.wav",
                           mime: String = "audio/wav") async throws -> String {
        var req = request("/api/v1/audio/transcriptions", method: "POST")
        let form = OWMultipart()
        form.appendFile(name: "file", filename: filename, mime: mime, fileData: audio)
        req.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = form.finalized
        struct R: Decodable { var text: String }
        return try decode(R.self, try await send(req, long: true)).text
    }

    /// GET /api/v1/audio/voices — voices available for the server's TTS engine.
    /// Best-effort: returns `[]` if the server doesn't expose the endpoint.
    public func audioVoices() async -> [OWVoice] {
        guard let data = try? await send(request("/api/v1/audio/voices")) else { return [] }
        if let arr = try? JSONDecoder().decode([OWVoice].self, from: data) { return arr }
        struct Wrap: Decodable { var voices: [OWVoice] }
        if let w = try? JSONDecoder().decode(Wrap.self, from: data) { return w.voices }
        return []
    }
}
