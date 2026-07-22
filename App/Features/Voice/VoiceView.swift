import SwiftUI
import OpenWebUIKit

/// An existing chat to resume in voice mode (passed from a chat's voice button).
struct VoiceSeed: Identifiable {
    let id = UUID()
    let chatID: String?
    let messages: [OWMessage]
    var model: String? = nil
}

/// Voice-first conversation screen — a hands-free "talk to it" companion.
/// Tap the orb to start; it then loops listen → think → speak on its own.
///
/// Two entry points: the **Voz tab** (always a fresh conversation) and a chat's
/// voice button (`seed` set → resumes that conversation, saving back to it).
struct VoiceView: View {
    let app: AppState
    let seed: VoiceSeed?
    /// Hands completed voice turns back to the host chat (shared thread + context).
    let onCommit: (([OWMessage]) -> Void)?
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @StateObject private var convo: VoiceConversation
    @ObservedObject private var speech = SpeechManager.shared

    init(app: AppState, seed: VoiceSeed? = nil, onCommit: (([OWMessage]) -> Void)? = nil) {
        self.app = app
        self.seed = seed
        self.onCommit = onCommit
        _convo = StateObject(wrappedValue: VoiceConversation(client: app.client,
                                                             completions: app.completions,
                                                             models: app.models,
                                                             defaultModel: app.defaultModel))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                theme.bg.ignoresSafeArea()
                if theme.backdrop { ThemeBackdrop(theme: theme) }
                VStack(spacing: 0) {
                    transcript                 // fills — live text stays visible
                    bottomDock                 // spectrum + state + controls
                }
                .padding(16)
            }
            .navigationTitle("Voz")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // No "Close" here — the ✕ control at the bottom exits. Keep only
                    // the new-conversation button for the standalone Voz screen.
                    if seed == nil, !convo.turns.isEmpty {
                        Button { convo.reset() } label: { Image(systemName: "square.and.pencil") }
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    voicePicker
                    modelPicker
                }
            }
        }
        .tint(theme.accent)
        .onAppear {
            if speech.useServer { Task { await speech.loadServerVoices() } }
            convo.onCommit = onCommit   // route turns into the host chat
            convo.contextProvider = { app.contextSystemMessage() }   // date/time, location, instructions
            if let seed { convo.seedOnce(chatID: seed.chatID, messages: seed.messages, model: seed.model) }
            else if !convo.active { convo.reset() }
            // Auto-start listening on open, ChatGPT-style — no manual "Iniciar".
            if !convo.active { Task { await convo.startSession() } }
        }
    }

    /// Per-conversation TTS voice (only for the server engine, which advertises voices).
    @ViewBuilder private var voicePicker: some View {
        if speech.useServer && !speech.serverVoices.isEmpty {
            Menu {
                Button("Voz padrão") { convo.setVoice("") }
                ForEach(speech.serverVoices) { v in Button(v.name) { convo.setVoice(v.id) } }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "person.wave.2").font(.system(size: 9))
                    Text(speech.serverVoices.first { $0.id == convo.ttsVoice }?.name ?? L("Voz"))
                        .font(.ody(size: 11, design: .monospaced)).lineLimit(1)
                }.foregroundStyle(theme.accent)
            }
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(convo.turns) { turn in
                        bubble(turn).id(turn.id)
                    }
                    if !convo.liveText.isEmpty {
                        bubble(.init(role: "user", text: convo.liveText)).opacity(0.6)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }
            .onChange(of: convo.turns.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: convo.reply) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            // Keep your live transcription in view above the dock as you speak.
            .onChange(of: convo.liveText) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private func bubble(_ turn: VoiceConversation.Turn) -> some View {
        let isUser = turn.role == "user"
        return HStack {
            if isUser { Spacer(minLength: 40) }
            Text(turn.text.isEmpty ? "…" : turn.text)
                .font(.ody(.subheadline, design: .monospaced))
                .foregroundStyle(isUser ? theme.fg : theme.fg)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(isUser ? theme.userBubble : theme.aiBubble,
                            in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.border, lineWidth: 1))
            if !isUser { Spacer(minLength: 40) }
        }
    }

    // MARK: - Bottom dock (status + spectrum + controls)

    /// The whole voice affordance lives at the bottom: a status line, a theme-color
    /// FFT spectrum that reacts while listening (and shimmers while responding), and
    /// the mute / exit controls. The transcript owns the rest of the screen.
    private var bottomDock: some View {
        VStack(spacing: 12) {
            statusLine
            SpectrumVisualizer(source: convo.spectrumSource, phase: convo.phase, color: theme.accent)
                .frame(height: 56)
                .onTapGesture { convo.tapOrb() }
            controlButton
        }
        .padding(.top, 8)
    }

    private var statusLine: some View {
        Text(statusText)
            .font(.ody(.subheadline, design: .monospaced))
            .foregroundStyle(theme.secondaryText)
            .padding(.top, 14)
            .multilineTextAlignment(.center)
    }

    private var statusText: String {
        if let e = convo.error { return e }
        switch convo.phase {
        case .idle:      return convo.active ? "…" : L("Toque para conversar")
        case .listening: return L("Ouvindo…")
        case .thinking:  return L("Pensando…")
        case .speaking:  return L("Falando…")
        }
    }

    // MARK: - Controls

    /// ChatGPT-style bottom controls: mute (left), exit (right). The session
    /// auto-starts, so there's no explicit "start" — tapping mute or the orb
    /// manages the mic; exit ends it. If nothing's running, mute doubles as start.
    private var controlButton: some View {
        HStack {
            circleControl(convo.muted ? "mic.slash.fill" : "mic.fill",
                          on: convo.muted) {
                if !convo.active { Task { await convo.startSession() } }
                else { convo.toggleMute() }
            }
            Spacer()
            circleControl("xmark", on: false) {
                convo.stop()
                dismiss()
            }
        }
        .padding(.horizontal, 24)
    }

    private func circleControl(_ system: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(on ? .white : theme.fg)
                .frame(width: 60, height: 60)
                .background(on ? theme.accent : theme.panel, in: Circle())
                .overlay(Circle().stroke(theme.border.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var modelPicker: some View {
        Menu {
            ForEach(convo.models) { m in Button(m.shortName) { convo.model = m.id } }
        } label: {
            HStack(spacing: 3) {
                Text(convo.models.first { $0.id == convo.model }?.shortName ?? L("Modelo"))
                    .font(.ody(size: 11, design: .monospaced)).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8))
            }
            .foregroundStyle(theme.accent).frame(maxWidth: 140, alignment: .trailing)
        }
    }
}

/// Holds the latest FFT bands and eases them toward the target every frame. It's
/// a plain reference (not @Published) so the audio spectrum — which arrives only a
/// few times per second — doesn't re-render the whole voice screen and fight the
/// 60fps animation (that was the stutter). The Canvas reads it each frame.
final class SpectrumSource {
    private var target = [Float](repeating: 0, count: VoiceInputManager.bandCount)
    private(set) var display = [Float](repeating: 0, count: VoiceInputManager.bandCount)
    func set(_ b: [Float]) { if b.count == target.count { target = b } }
    func clear() { for i in target.indices { target[i] = 0 } }
    /// Ease toward the target; call once per rendered frame.
    func tick() { for i in display.indices { display[i] += (target[i] - display[i]) * 0.35 } }
}

/// A horizontal FFT spectrum bar (center-mirrored) in the theme color. While
/// LISTENING it renders the live FFT bands; while THINKING/SPEAKING it shows an
/// animated shimmer to signal activity (the mic is idle then); otherwise a faint
/// baseline. Redraws every frame via TimelineView.
struct SpectrumVisualizer: View {
    var source: SpectrumSource
    var phase: VoiceConversation.Phase
    var color: Color

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                source.tick()                 // ease bars toward the latest FFT
                let bands = source.display
                let n = 28
                let slot = size.width / CGFloat(n)
                let barW = slot * 0.6
                let midY = size.height / 2
                for i in 0..<n {
                    let frac = Double(i) / Double(n)
                    var h: CGFloat
                    switch phase {
                    case .listening:
                        h = CGFloat(i < bands.count ? bands[i] : 0)
                    case .speaking, .thinking:
                        // No mic input while responding → animated shimmer instead.
                        let s = (sin(t * 4 + frac * 9) + sin(t * 2.7 + frac * 15)) / 2   // -1…1
                        h = 0.16 + 0.34 * CGFloat((s + 1) / 2)
                    default:
                        h = 0.03
                    }
                    let barH = max(3, h * size.height)
                    let x = CGFloat(i) * slot + (slot - barW) / 2
                    let rect = CGRect(x: x, y: midY - barH / 2, width: barW, height: barH)
                    // Center bars a touch brighter for a nice equalizer falloff.
                    let bright = 0.55 + 0.45 * (1 - abs(frac - 0.5) * 2)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: barW / 2),
                             with: .color(color.opacity(0.35 + 0.5 * bright)))
                }
            }
        }
    }
}
