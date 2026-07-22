import Foundation
import Combine
#if os(iOS)
import UIKit
#endif
import OpenWebUIKit

/// Hands-free voice conversation: **listen → think → speak → listen**, looping
/// until stopped. It glues together the existing STT (`VoiceInputManager`) and
/// TTS (`SpeechManager`) engines with a streamed LLM reply.
///
/// This is the seed of app #2 (the voice-first companion); it lives in the app
/// layer because it depends on Speech/AVFoundation, while the model talk stays in
/// `OpenWebUIKit`.
@MainActor
final class VoiceConversation: ObservableObject {
    enum Phase: Equatable { case idle, listening, thinking, speaking }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var active = false
    @Published var turns: [Turn] = []
    @Published var liveText = ""        // partial user transcription while listening
    @Published var reply = ""           // streaming assistant reply
    @Published var error: String?
    @Published var model: String?
    /// Live mic loudness (0…1) — used internally for energy endpointing. NOT
    /// @Published: it changes many times/sec and the view doesn't read it, so
    /// publishing it just churned re-renders.
    private var level: Float = 0
    /// Live FFT bands for the visualizer — a plain reference the Canvas reads each
    /// frame (see SpectrumSource) so the fast audio updates don't re-render the view.
    let spectrumSource = SpectrumSource()
    /// Per-conversation server TTS voice ("" = global default). Persisted per chat.
    @Published var ttsVoice: String = ""

    struct Turn: Identifiable, Equatable { var id: String = UUID().uuidString; let role: String; var text: String; var at = Date() }

    let models: [OWModel]
    private let client: OpenWebUIClient
    private let completions: ChatCompletionsClient
    private let voice = VoiceInputManager()
    private let tts = SpeechManager.shared
    private let bargeMonitor = BargeInMonitor()

    /// Server chat this voice session is being saved to (created on first reply).
    private var chatID: String?

    /// When set (voice launched from a chat), completed turns are handed to the
    /// host `ChatViewModel` instead of being saved here — so voice and text share
    /// one thread, carry over both ways, and honor the chat's mode (server/local/
    /// temporary). nil = legacy standalone behaviour (self-persist to the server).
    var onCommit: (([OWMessage]) -> Void)?

    private var cancellables = Set<AnyCancellable>()
    private var silenceTimer: Timer?
    private var lastPartial = ""
    private var lastChange = Date()
    // Energy-based endpointing (for engines with no live transcript).
    private var heardSpeech = false
    private var lastLoud = Date()
    // Matched to VoiceInputManager's boosted 0…1 level: a normal voice reads
    // ~0.35–0.6, room noise ~0.05–0.15, so this cleanly separates speech.
    private let speechLevel: Float = 0.22
    // The conversation forces the native engine (see init), so endpointing always
    // uses the live-transcript path: end the turn on a pause after real words.
    private let sttIsNative = true
    private var streamTask: Task<Void, Never>?
    private var speakingTurnID = ""

    /// How long the transcription must stay unchanged before we treat the turn as
    /// finished (native engine only — Whisper has no live partials, so there the
    /// user taps the orb to end the turn).
    private let endpointSilence: TimeInterval = 1.6

    /// Mic-based barge-in (talk over the reply to interrupt). OFF by default: it
    /// needs a duplex `.voiceChat` session + a second audio engine for echo
    /// cancellation, which glitched the tail of the spoken reply. You can still
    /// interrupt by tapping the orb. Opt in via the Settings toggle.
    private var bargeInEnabled: Bool {
        UserDefaults.standard.object(forKey: "voice.bargein.enabled") as? Bool ?? false
    }

    private var seeded = false

    init(client: OpenWebUIClient, completions: ChatCompletionsClient, models: [OWModel],
         defaultModel: String? = nil) {
        self.client = client
        self.completions = completions
        self.models = models
        // Voice needs tools (weather / web search), so prefer the fast Agent model;
        // fall back to the user's default. The picker still overrides per session.
        self.model = models.first { $0.id.hasSuffix(".agent") || $0.name == "Agent (tools)" }?.id
            ?? defaultModel ?? models.first?.id
        voice.client = client   // enables the "server" STT engine
        // The live conversation forces on-device recognition: it's the only engine
        // that streams partial transcripts (so you see your words as you speak) and
        // that we can auto-endpoint on a pause without a manual tap.
        voice.engineOverride = "native"
        voice.$partialText
            .receive(on: RunLoop.main)
            .sink { [weak self] t in self?.partialChanged(t) }
            .store(in: &cancellables)
        voice.$level
            .receive(on: RunLoop.main)
            .sink { [weak self] lvl in self?.levelChanged(lvl) }
            .store(in: &cancellables)
        voice.$spectrum
            .receive(on: RunLoop.main)
            .sink { [weak self] s in
                guard let self else { return }
                self.spectrumSource.set(self.phase == .listening ? s : [])
            }
            .store(in: &cancellables)
        voice.$error
            .receive(on: RunLoop.main)
            .sink { [weak self] e in if let e { self?.error = e } }
            .store(in: &cancellables)
        // Recover the loop if neural TTS fails to produce audio.
        tts.$neuralError
            .receive(on: RunLoop.main)
            .sink { [weak self] e in
                guard let self, let e, self.phase == .speaking else { return }
                self.error = e
                self.afterSpeaking()
            }
            .store(in: &cancellables)
    }

    // MARK: - Session control

    func toggleSession() {
        if active { stop() } else { Task { await startSession() } }
    }

    /// Mute/unmute the mic without ending the session (ChatGPT-style). While muted
    /// the input is discarded and endpointing is paused.
    @Published var muted = false
    func toggleMute() {
        muted.toggle()
        voice.muted = muted
        if muted { liveText = "" }        // drop the in-progress partial
        else { lastChange = Date(); lastLoud = Date() }   // reset the pause clock
    }

    /// Loads an existing server chat so voice continues it (one-time, used when
    /// opening the voice screen from a chat's voice button). Carries the chat's
    /// model and its saved per-conversation voice.
    func seedOnce(chatID: String?, messages: [OWMessage], model seedModel: String? = nil) {
        guard !seeded else { return }
        seeded = true
        self.chatID = chatID
        turns = messages.map { m in
            Turn(id: m.id,
                 role: m.role == .user ? "user" : "assistant",
                 text: m.content,
                 at: m.timestamp.map { Date(timeIntervalSince1970: $0) } ?? Date())
        }
        model = seedModel ?? messages.last(where: { $0.role == .assistant })?.model ?? model
        if let id = chatID { ttsVoice = UserDefaults.standard.string(forKey: Self.voiceKey(id)) ?? "" }
    }

    /// Sets this conversation's TTS voice (and remembers it for the chat).
    func setVoice(_ v: String) {
        ttsVoice = v
        if let id = chatID { UserDefaults.standard.set(v, forKey: Self.voiceKey(id)) }
    }

    private static func voiceKey(_ id: String) -> String { "voice.chat.\(id).ttsVoice" }

    /// Clears everything for a brand-new conversation (the Voz tab always starts fresh).
    func reset() {
        stop()
        turns = []; reply = ""; liveText = ""; error = nil
        chatID = nil; seeded = false; ttsVoice = ""
    }

    func startSession() async {
        guard !active else { return }
        active = true; error = nil; reply = ""
        // Duplex (play-AND-record) only when mic barge-in is on; otherwise a clean
        // `.playback` session so the spoken reply doesn't glitch at the end.
        tts.duplexSession = bargeInEnabled
        enableProximity()
        await listen()
    }

    func stop() {
        active = false
        streamTask?.cancel(); streamTask = nil
        silenceTimer?.invalidate(); silenceTimer = nil
        bargeMonitor.stop()
        tts.onSpeechFinished = nil
        tts.duplexSession = false
        tts.stop()
        voice.cancel()
        disableProximity()
        phase = .idle
        liveText = ""
    }

    // MARK: - Proximity (raise-to-ear → earpiece, else loudspeaker)

    private var proximityObserver: NSObjectProtocol?

    private func enableProximity() {
        #if os(iOS)
        UIDevice.current.isProximityMonitoringEnabled = true
        NotificationCenter.default
            .publisher(for: UIDevice.proximityStateDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.tts.applyProximityRoute()
            }
            .store(in: &cancellables)
        #endif
    }

    private func disableProximity() {
        #if os(iOS)
        // Os observers do Combine já serão cancelados automaticamente via cancellables
        UIDevice.current.isProximityMonitoringEnabled = false
        #endif
    }

    /// Tap the orb mid-turn: end listening early, or skip the spoken reply.
    func tapOrb() {
        switch phase {
        case .listening: endTurn()
        case .speaking:  bargeIn()
        case .thinking, .idle: break
        }
    }

    // MARK: - Listen (STT)

    private func listen() async {
        guard active else { return }
        reply = ""; liveText = ""; lastPartial = ""
        heardSpeech = false
        guard await voice.start() else { active = false; phase = .idle; return }
        phase = .listening
        lastChange = Date(); lastLoud = Date()
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkSilence() }
        }
    }

    private func partialChanged(_ t: String) {
        guard phase == .listening else { return }
        liveText = t
        if t != lastPartial { lastPartial = t; lastChange = Date() }
    }

    private func levelChanged(_ lvl: Float) {
        // Throttle UI churn: only republish on a meaningful change so the orb's
        // (blur/shadow) layers don't re-render on every audio callback.
        let next: Float = (phase == .listening) ? lvl : 0
        if abs(next - level) > 0.02 { level = next }
        guard phase == .listening else { return }
        if lvl > speechLevel { heardSpeech = true; lastLoud = Date() }
    }

    private func checkSilence() {
        guard phase == .listening, !muted else { return }
        if sttIsNative {
            // Native has a live transcript — end on a pause after real words.
            guard !lastPartial.isEmpty else { return }
            if Date().timeIntervalSince(lastChange) > endpointSilence { endTurn() }
        } else {
            // Server/Whisper: no live transcript → end on a pause after hearing speech.
            guard heardSpeech else { return }
            if Date().timeIntervalSince(lastLoud) > endpointSilence { endTurn() }
        }
    }

    private func endTurn() {
        guard phase == .listening else { return }
        silenceTimer?.invalidate(); silenceTimer = nil
        phase = .thinking          // freeze the silence watcher; stop() finalizes STT
        Task {
            let text = await voice.stop()
            guard active else { return }
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { await listen(); return }   // heard nothing → keep listening
            turns.append(Turn(role: "user", text: t))
            liveText = ""
            ask(t)
        }
    }

    // MARK: - Think (LLM)

    private func ask(_ userText: String) {
        guard let model else { error = L("Nenhum modelo disponível."); phase = .idle; return }
        phase = .thinking
        reply = ""
        var msgs = [OWChatMessageInput(role: "system", text: Self.systemPrompt)]
        for t in turns { msgs.append(OWChatMessageInput(role: t.role, text: t.text)) }
        let replyTurn = Turn(role: "assistant", text: "")
        turns.append(replyTurn)
        speakingTurnID = replyTurn.id
        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await u in self.completions.stream(model: model, messages: msgs) {
                    if Task.isCancelled { return }
                    switch u {
                    case .textDelta(let d):
                        self.reply += d
                        if let i = self.turns.lastIndex(where: { $0.id == replyTurn.id }) {
                            self.turns[i].text = Self.cleanReply(self.reply)
                        }
                    case .error(let m): self.error = m
                    default: break
                    }
                }
                self.commit()
                self.speak()
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.afterSpeaking()
            }
        }
    }

    /// Turns rendered as chat messages (drops empty ones).
    private func currentMessages() -> [OWMessage] {
        turns.compactMap { t in
            let txt = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !txt.isEmpty else { return nil }
            return OWMessage(id: t.id,
                             role: t.role == "user" ? .user : .assistant,
                             content: txt,
                             model: t.role == "user" ? nil : model,
                             timestamp: t.at.timeIntervalSince1970)
        }
    }

    /// Hand the turn off to the host chat if attached; otherwise self-persist.
    private func commit() {
        if let onCommit {
            onCommit(currentMessages())
        } else {
            Task { await persist() }
        }
    }

    /// Saves the conversation to Open WebUI so it shows up in "Conversas"
    /// (creates the chat on the first reply, then updates it each turn).
    private func persist() async {
        guard let model else { return }
        let msgs: [OWMessage] = turns.compactMap { t in
            let txt = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !txt.isEmpty else { return nil }
            return OWMessage(id: t.id,
                             role: t.role == "user" ? .user : .assistant,
                             content: txt,
                             model: t.role == "user" ? nil : model,
                             timestamp: t.at.timeIntervalSince1970)
        }
        guard msgs.count >= 2 else { return }
        let firstUser = turns.first { $0.role == "user" }?.text ?? L("Conversa de voz")
        let title = String(firstUser.prefix(50))
        do {
            if let id = chatID {
                try await client.updateChat(id: id, title: title, model: model, messages: msgs)
            } else {
                let id = try await client.createChat(title: title, model: model, messages: msgs)
                chatID = id
                if !ttsVoice.isEmpty { UserDefaults.standard.set(ttsVoice, forKey: Self.voiceKey(id)) }
            }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Speak (TTS)

    /// Clean a reply for speaking + display: drop the Agent's appended Sources
    /// block and markdown syntax, and trim the leading blank lines (the "space
    /// above the text") that thinking-off replies start with.
    static func cleanReply(_ raw: String) -> String {
        var s = raw
        if let r = s.range(of: "\n\n---", options: .backwards) { s = String(s[..<r.lowerBound]) }
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[*_`#>]"#, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func speak() {
        let t = Self.cleanReply(reply)
        guard active, !t.isEmpty else { afterSpeaking(); return }
        phase = .speaking
        tts.voiceOverride = ttsVoice.isEmpty ? nil : ttsVoice
        tts.onSpeechFinished = { [weak self] in self?.afterSpeaking() }
        tts.toggle(t, id: speakingTurnID)
        // Listen for the user cutting in (barge-in) while the reply plays — opt-in.
        if bargeInEnabled { bargeMonitor.start { [weak self] in self?.bargeIn() } }
    }

    /// User started talking over the reply → stop speaking and listen.
    private func bargeIn() {
        guard phase == .speaking else { return }
        bargeMonitor.stop()
        tts.onSpeechFinished = nil   // transition ourselves (AVAudioPlayer.stop fires no callback)
        tts.stop()
        afterSpeaking()
    }

    private func afterSpeaking() {
        bargeMonitor.stop()
        tts.onSpeechFinished = nil
        guard active else { phase = .idle; return }
        // Let the playback tail drain before switching the session back to record —
        // an immediate switch clips/repeats the last hardware buffer (the end click).
        Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard self.active, self.phase != .listening else { return }
            await self.listen()
        }
    }

    /// Follows the app's selected UI language instead of forcing pt-BR — the
    /// prompt previously hard-coded "falando português do Brasil", so the agent
    /// always replied in Portuguese regardless of the user's language.
    static var systemPrompt: String {
        let language = LanguageManager.shared.current.endonym   // e.g. "English", "Português"
        return """
        You are a friendly voice companion. Reply in \(language) (unless the user \
        clearly speaks another language, then match theirs). Keep replies short and \
        natural — 1 to 3 sentences, like spoken conversation. No lists, markdown, or \
        emoji, just fluid speech.
        """
    }
}
