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
    @State private var breathe = false

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
                    transcript
                    Spacer(minLength: 8)
                    orb
                    statusLine
                    Spacer(minLength: 8)
                    controlButton
                }
                .padding(16)
            }
            .navigationTitle("Voz")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if seed != nil {
                        Button("Fechar") { convo.stop(); dismiss() }.foregroundStyle(theme.accent)
                    } else if !convo.turns.isEmpty {
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
            if let seed { convo.seedOnce(chatID: seed.chatID, messages: seed.messages, model: seed.model) }
            else if !convo.active { convo.reset() }
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
            .onChange(of: convo.turns.count) { _, _ in withAnimation { proxy.scrollTo("bottom") } }
            .onChange(of: convo.reply) { _, _ in proxy.scrollTo("bottom") }
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

    // MARK: - Orb

    /// ChatGPT-style soft white blob (no icon). It breathes slowly, swells with
    /// your voice while listening, glows brighter while speaking, and shows a
    /// spinner while thinking. An accent aura keeps it visible on light themes.
    private var orb: some View {
        let amp = convo.phase == .listening ? CGFloat(min(max(convo.level, 0), 1)) : 0
        let active = convo.phase == .listening || convo.phase == .speaking
        return ZStack {
            Circle()
                .fill(RadialGradient(colors: [theme.accent.opacity(0.35), .clear],
                                     center: .center, startRadius: 20, endRadius: 150))
                .frame(width: 300, height: 300)
                .scaleEffect(breathe ? 1.06 : 0.9)
            Circle()
                .fill(RadialGradient(colors: [.white, .white.opacity(0.85), .white.opacity(0.2)],
                                     center: .init(x: 0.42, y: 0.40), startRadius: 6, endRadius: 120))
                .frame(width: 176, height: 176)
                .blur(radius: 3)
                .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 1).blur(radius: 1))
                .shadow(color: .white.opacity(active ? 0.6 : 0.3), radius: active ? 34 : 18)
                .scaleEffect(0.9 + amp * 0.35 + (breathe ? 0.05 : 0))
            if convo.phase == .thinking {
                ProgressView().tint(theme.accent).controlSize(.large)
            }
        }
        .frame(height: 300)
        .contentShape(Circle())
        .onTapGesture { convo.tapOrb() }
        .animation(.easeOut(duration: 0.12), value: amp)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { breathe = true }
        }
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

    private var controlButton: some View {
        Button { convo.toggleSession() } label: {
            HStack(spacing: 8) {
                Image(systemName: convo.active ? "stop.fill" : "mic.fill")
                Text(LocalizedStringKey(convo.active ? "Encerrar" : "Iniciar conversa"))
                    .font(.ody(.headline, design: .monospaced))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 15)
            .background(convo.active ? theme.panel : theme.accent,
                        in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(convo.active ? theme.accent : .white)
            .overlay(RoundedRectangle(cornerRadius: 14)
                .stroke(convo.active ? theme.accent : .clear, lineWidth: 1))
        }
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
