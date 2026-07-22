import SwiftUI
import UniformTypeIdentifiers
import PhotosUI
import OpenWebUIKit

struct ChatScreen: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var vm: ChatViewModel
    @StateObject private var voice = VoiceInputManager()
    @FocusState private var inputFocused: Bool
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showCamera = false
    @State private var showDocPicker = false
    @State private var showNotePicker = false
    @State private var showChatPicker = false
    @State private var showKBPicker = false
    @State private var showWebInput = false
    @State private var webURL = ""
    @State private var comingSoon: String?
    @State private var showVoice = false

    init(app: AppState, chat: OWChatSummary?, mode: ChatMode? = nil, onChanged: @escaping () -> Void) {
        let model = app.makeChatViewModel(chat: chat, mode: mode)
        model.onChanged = onChanged
        _vm = StateObject(wrappedValue: model)
    }

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                messages
                composer
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    HStack(spacing: 6) {
                        if vm.mode != .server {
                            Image(systemName: vm.mode.symbol)
                                .font(.ody(size: 11)).foregroundStyle(theme.accent)
                        }
                        Text(vm.title)
                            .font(.ody(.headline, design: .monospaced))
                            .foregroundStyle(theme.fg).lineLimit(1)
                    }
                    modelMenu
                }
            }
            // Mode picker (Claude-style ghost affordance, generalized to three
            // modes): choose server / on-device / temporary while the chat is
            // still empty. Locks once the conversation starts.
            ToolbarItem(placement: .topBarTrailing) {
                if vm.canChangeMode {
                    Menu {
                        Picker("Modo da conversa", selection: Binding(get: { vm.mode }, set: { vm.setMode($0) })) {
                            ForEach(ChatMode.allCases, id: \.self) { m in
                                Label(m.label, systemImage: m.symbol).tag(m)
                            }
                        }
                    } label: {
                        Image(systemName: vm.mode.symbol)
                            .foregroundStyle(vm.mode == .server ? theme.secondaryText : theme.accent)
                    }
                    .accessibilityLabel(Text("Modo da conversa"))
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showVoice = true } label: {
                    Image(systemName: "waveform").foregroundStyle(theme.accent)
                }
            }
        }
        .onAppear {
            vm.loadHistoryIfNeeded()
            voice.client = app.client
            // "Take a Photo to Ask" App Intent → pop the camera on a fresh chat.
            if vm.chatID == nil, AppLaunch.shared.openCameraOnNewChat {
                AppLaunch.shared.openCameraOnNewChat = false
                showCamera = true
            }
        }
        // Coming back from the background: re-fetch so messages/images created
        // meanwhile on the web UI show up (unless we're mid-stream).
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, !vm.isStreaming, vm.chatID != nil {
                Task { await vm.reloadHistory() }
            }
        }
        .fullScreenCover(isPresented: $showVoice) {
            VoiceView(app: app,
                      seed: VoiceSeed(chatID: vm.chatID, messages: vm.messages, model: vm.selectedModel),
                      onCommit: { vm.ingestVoiceTurns($0) })
                .environment(\.theme, theme)
        }
    }

    private var modelMenu: some View {
        Menu {
            ForEach(app.models) { m in
                Button { vm.selectModel(m.id) } label: {
                    if vm.selectedModel == m.id {
                        Label(m.shortName, systemImage: "checkmark")
                    } else {
                        Text(m.shortName)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(vm.selectedModelName).font(.ody(size: 10, design: .monospaced))
                Image(systemName: "chevron.down").font(.system(size: 8))
            }
            .foregroundStyle(theme.secondaryText)
        }
    }

    // MARK: - Messages

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if vm.isLoadingHistory && vm.messages.isEmpty {
                    ProgressView().tint(theme.accent).padding(.top, 80)
                } else if vm.messages.isEmpty {
                    welcome.padding(.top, 60)
                }
                LazyVStack(spacing: 16) {
                    ForEach(Array(vm.messages.enumerated()), id: \.element.id) { idx, msg in
                        let streaming = vm.isStreaming && idx == vm.messages.count - 1 && msg.role == .assistant
                        MessageBubble(
                            message: msg,
                            isStreaming: streaming,
                            client: app.client,
                            branch: vm.branchInfo(for: msg.id),
                            models: app.models,
                            // Tool activity ("🔧 web_search: …") shows inline under this
                            // reply while it runs — only on the message being generated.
                            toolStatus: streaming ? vm.toolStatus : nil,
                            onEdit: msg.role == .user ? { vm.editUser(messageID: msg.id, newText: $0) } : nil,
                            onRegenerate: msg.role == .assistant ? { vm.regenerate(messageID: msg.id) } : nil,
                            onRetryModel: msg.role == .assistant ? { vm.regenerate(messageID: msg.id, model: $0) } : nil,
                            onBranch: { vm.switchBranch(messageID: msg.id, delta: $0) }
                        )
                        .id(msg.id)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 16)
                Color.clear.frame(height: 1).id("bottom")
            }
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await vm.reloadHistory() }
            .onChange(of: vm.messages.last?.content) { _, _ in scrollToBottom(proxy) }
            .onChange(of: vm.messages.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: vm.toolStatus) { _, _ in scrollToBottom(proxy) }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    private var welcome: some View {
        VStack(spacing: 14) {
            BrandMark(size: 56)
            Text("Como posso ajudar?")
                .font(.ody(.title2, design: .monospaced).weight(.semibold))
                .foregroundStyle(theme.fg)
            Text(app.serverConfig.baseURL.host ?? "Open WebUI")
                .font(.ody(.footnote, design: .monospaced))
                .foregroundStyle(theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 8) {
            if vm.isStreaming { Divider().overlay(theme.border) }
            HStack(spacing: 8) {
                featuresMenu
                toggleChip(system: "photo.artframe", label: "Gerar imagem", on: $vm.imageMode)
                if !app.tools.isEmpty { toolChip }
                Spacer()
            }
            .padding(.horizontal, 12)
            if let err = vm.error ?? voice.error {
                Text(err)
                    .font(.ody(size: 11, design: .monospaced))
                    .foregroundStyle(theme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
            }
            if !vm.pendingImageURLs.isEmpty || !vm.pendingDocuments.isEmpty || vm.uploading { pendingStrip }
            HStack(alignment: .bottom, spacing: 8) {
                attachButton
                micButton
                TextField(inputPrompt, text: inputBinding, axis: .vertical)
                    .font(.ody(.body, design: .monospaced))
                    .foregroundStyle(theme.fg)
                    .focused($inputFocused)
                    .lineLimit(1...6)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(theme.panel, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(theme.border, lineWidth: 1))
                sendButton
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
        }
        .background(theme.bg)
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 4, matching: .images)
        .onChange(of: photoItems) { _, items in loadPhotos(items) }
        #if os(iOS)
        .sheet(isPresented: $showCamera) { CameraPicker { data in vm.addImageData([data]) } }
        .sheet(isPresented: $showDocPicker) {
            DocumentPicker { data, name, mime in Task { await vm.addDocument(data: data, filename: name, mime: mime) } }
        }
        #else
        .fileImporter(isPresented: $showDocPicker,
                      allowedContentTypes: [.pdf, .plainText, .text, .rtf, .commaSeparatedText, .json, .data]) { result in
            guard case .success(let url) = result else { return }
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            Task { await vm.addDocument(data: data, filename: url.lastPathComponent, mime: mime) }
        }
        #endif
        .sheet(isPresented: $showNotePicker) {
            NotePickerSheet(client: app.client) { note in Task { await vm.attachNote(note) } }
        }
        .sheet(isPresented: $showChatPicker) {
            ChatPickerSheet(client: app.client) { c in Task { await vm.attachChatReference(c) } }
        }
        .sheet(isPresented: $showKBPicker) {
            KBPickerSheet(client: app.client) { kb in vm.attachKnowledge(kb) }
        }
        .alert("Anexar Página Web", isPresented: $showWebInput) {
            TextField("https://…", text: $webURL)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            Button("Anexar") { let u = webURL; webURL = ""; Task { await vm.attachWebPage(u) } }
            Button("Cancelar", role: .cancel) { webURL = "" }
        } message: { Text("A página é lida no servidor e anexada como contexto.") }
        .alert("Em breve", isPresented: Binding(get: { comingSoon != nil }, set: { if !$0 { comingSoon = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(comingSoon ?? "") }
    }

    private var inputPrompt: LocalizedStringKey {
        if voice.isRecording { return "Ouvindo…" }
        return vm.imageMode ? "Descreva a imagem…" : "Mensagem…"
    }
    private var inputBinding: Binding<String> {
        voice.isRecording ? .constant(voice.partialText) : $vm.input
    }

    /// The "+" attach menu (print 1).
    private var attachButton: some View {
        Menu {
            Button { showPhotos = true } label: { Label("Carregar Arquivos", systemImage: "photo.on.rectangle") }
            #if os(iOS)
            Button { showCamera = true } label: { Label("Capturar", systemImage: "camera") }
            #endif
            Divider()
            Button { showWebInput = true } label: { Label("Anexar Página Web", systemImage: "globe") }
            Button { showDocPicker = true } label: { Label("Anexar arquivos", systemImage: "doc") }
            Button { showNotePicker = true } label: { Label("Anexar Notas", systemImage: "note.text") }
            Button { showKBPicker = true } label: { Label("Anexar Base de Conhecimento", systemImage: "cylinder.split.1x2") }
            Button { showChatPicker = true } label: { Label("Chats de Referência", systemImage: "clock.arrow.circlepath") }
            // Just the feature name (a brand, shown verbatim) — the localized
            // alert title "Em breve" already means "coming soon", so we don't
            // bake the pt-BR phrase into a String that Text() can't localize.
            Button { comingSoon = "Google Drive" } label: { Label("Google Drive", systemImage: "externaldrive") }
        } label: {
            Image(systemName: "plus")
                .font(.ody(size: 20))
                .foregroundStyle(theme.accent)
                .frame(width: 34, height: 42)
        }
    }

    private var pendingStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(vm.pendingImageURLs, id: \.self) { url in
                    ZStack(alignment: .topTrailing) {
                        AttachmentThumb(url: url, size: 56)
                        Button { vm.removePendingImage(url) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white, .black.opacity(0.5))
                        }
                        .offset(x: 5, y: -5)
                    }
                }
                ForEach(vm.pendingDocuments) { doc in
                    HStack(spacing: 6) {
                        Image(systemName: "doc.fill").font(.ody(size: 12)).foregroundStyle(theme.accent)
                        Text(doc.displayName).font(.ody(size: 11, design: .monospaced))
                            .foregroundStyle(theme.fg).lineLimit(1)
                        Button { vm.removePendingDocument(doc) } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(theme.secondaryText)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .frame(maxWidth: 180)
                    .background(theme.panel, in: Capsule())
                    .overlay(Capsule().stroke(theme.border, lineWidth: 1))
                }
                if vm.uploading {
                    ProgressView().frame(width: 56, height: 56)
                        .background(theme.panel, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task {
            var datas: [Data] = []
            for item in items {
                if let d = try? await item.loadTransferable(type: Data.self) { datas.append(d) }
            }
            vm.addImageData(datas)
            photoItems = []
        }
    }

    private var micButton: some View {
        Button { Task { await toggleMic() } } label: {
            ZStack {
                if voice.processing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: voice.isRecording ? "stop.circle.fill" : "mic")
                        .font(.ody(size: 20))
                        .foregroundStyle(voice.isRecording ? theme.accent : theme.secondaryText)
                        .symbolEffect(.pulse, isActive: voice.isRecording)
                }
            }
            .frame(width: 34, height: 42)
        }
        .disabled(voice.processing)
    }

    private func toggleMic() async {
        if voice.isRecording {
            appendTranscript(await stopVoiceCapturing())
            inputFocused = true
        } else {
            _ = await voice.start()
        }
    }

    /// Stop recording, falling back to the partial text if the final pass is empty
    /// (fixes the occasional lost-transcription).
    private func stopVoiceCapturing() async -> String {
        let partial = voice.partialText
        let text = await voice.stop()
        return text.isEmpty ? partial : text
    }

    private func appendTranscript(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        vm.input = vm.input.isEmpty ? t : vm.input + " " + t
    }

    private var sendButton: some View {
        Button {
            if voice.isRecording {
                Task { appendTranscript(await stopVoiceCapturing()); inputFocused = false; if canSend { submitComposer() } }
            } else if vm.isStreaming {
                vm.stop()
            } else {
                submitComposer(); inputFocused = false
            }
        } label: {
            Image(systemName: vm.isStreaming ? "stop.fill" : "arrow.up")
                .font(.ody(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background((canSend || vm.isStreaming || voice.isRecording) ? theme.accent : theme.border, in: Circle())
        }
        .disabled(!voice.isRecording && !vm.isStreaming && !canSend)
    }

    /// Open WebUI per-turn feature flags (web search / image generation / code
    /// interpreter), consolidated into one chip-styled menu.
    private var featuresMenu: some View {
        let active = vm.webSearch || vm.imageGeneration || vm.codeInterpreter
        return Menu {
            Toggle(isOn: $vm.webSearch) { Label("Buscar na web", systemImage: "globe") }
            Toggle(isOn: $vm.imageGeneration) { Label("Ilustrar resposta", systemImage: "photo") }
            Toggle(isOn: $vm.codeInterpreter) { Label("Executar código", systemImage: "chevron.left.forwardslash.chevron.right") }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "sparkles").font(.ody(size: 11))
                Text("Recursos").font(.ody(size: 12, design: .monospaced))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .foregroundStyle(active ? .white : theme.secondaryText)
            .background(active ? theme.accent : theme.panel, in: Capsule())
            .overlay(Capsule().stroke(theme.border, lineWidth: active ? 0 : 1))
        }
        .buttonStyle(.plain)
    }

    /// Enable/disable server tools (weather, MCP, …) for the next reply. Multi-
    /// select menu styled like the toggle chips; accented when any are on.
    private var toolChip: some View {
        let active = !vm.selectedToolIDs.isEmpty
        return Menu {
            ForEach(app.tools) { t in
                Button {
                    if vm.selectedToolIDs.contains(t.id) { vm.selectedToolIDs.remove(t.id) }
                    else { vm.selectedToolIDs.insert(t.id) }
                } label: {
                    Label(t.name, systemImage: vm.selectedToolIDs.contains(t.id) ? "checkmark" : "wrench.and.screwdriver")
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "wrench.and.screwdriver").font(.ody(size: 11))
                Text("Ferramentas").font(.ody(size: 12, design: .monospaced))
                if active { Text(verbatim: "\(vm.selectedToolIDs.count)").font(.ody(size: 11, design: .monospaced)) }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .foregroundStyle(active ? .white : theme.secondaryText)
            .background(active ? theme.accent : theme.panel, in: Capsule())
            .overlay(Capsule().stroke(theme.border, lineWidth: active ? 0 : 1))
        }
        .buttonStyle(.plain)
    }

    private func toggleChip(system: String, label: String, on: Binding<Bool>) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: system).font(.ody(size: 11))
                Text(LocalizedStringKey(label)).font(.ody(size: 12, design: .monospaced))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .foregroundStyle(on.wrappedValue ? .white : theme.secondaryText)
            .background(on.wrappedValue ? theme.accent : theme.panel, in: Capsule())
            .overlay(Capsule().stroke(theme.border, lineWidth: on.wrappedValue ? 0 : 1))
        }
        .buttonStyle(.plain)
    }

    private var canSend: Bool {
        let hasText = !vm.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Image generation uses the server's default image engine — no LLM needed.
        if vm.imageMode { return hasText }
        return (hasText || !vm.pendingImageURLs.isEmpty || !vm.pendingDocuments.isEmpty)
            && vm.selectedModel != nil
    }

    /// Route the composer's send action: image generation or a chat turn.
    private func submitComposer() {
        if vm.imageMode { vm.generateImage() } else { vm.send() }
    }
}
