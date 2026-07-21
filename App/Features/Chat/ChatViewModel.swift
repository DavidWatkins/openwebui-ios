import SwiftUI
import OpenWebUIKit

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [OWMessage] = []
    @Published var input: String = ""
    @Published var isStreaming = false
    @Published var isLoadingHistory = false
    @Published var error: String?
    @Published var selectedModel: String?
    @Published var title: String

    /// Images staged for the next message, as data: URLs (vision).
    @Published var pendingImageURLs: [String] = []
    /// Documents staged for the next message (uploaded → RAG).
    @Published var pendingDocuments: [OWAttachment] = []
    @Published var uploading = false
    /// Composer toggle: web search for the next reply.
    @Published var webSearch = false
    /// Composer toggle: the next prompt generates an image (server image engine)
    /// instead of a chat reply. Mutually exclusive with webSearch.
    @Published var imageMode = false { didSet { if imageMode { webSearch = false } } }
    /// Server tool/function ids enabled for the next reply (weather, MCP, …).
    /// Open WebUI runs the function-calling loop server-side when these are set.
    @Published var selectedToolIDs: Set<String> = []
    /// Live tool-progress line from the socket flow (e.g. "🔧 weather: Boston").
    @Published var toolStatus: String?
    /// Open WebUI per-turn feature flags (server generates an image from the reply /
    /// runs code). Distinct from `imageMode`, which is the manual image composer.
    @Published var imageGeneration = false
    @Published var codeInterpreter = false

    let models: [OWModel]

    /// Where this chat's history lives: server / on-device / ephemeral.
    /// Changeable via the mode control, but only while the chat is still empty.
    @Published private(set) var mode: ChatMode

    /// nil until the conversation is persisted (new chat). For `.local` chats
    /// this is the on-device id; for `.server` chats, the server id.
    private(set) var chatID: String?
    /// Fired after a turn finishes so the list can refresh.
    var onChanged: (() -> Void)?
    /// Supplies the ambient-context system message (date/time, location, custom
    /// instructions) to prepend to each turn. Evaluated per-send so it stays live.
    var contextProvider: (() -> OWChatMessageInput?)?

    private let client: OpenWebUIClient
    private let completions: ChatCompletionsClient
    private let localStore: LocalChatStore
    private var streamTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private var historyLoaded = false

    init(client: OpenWebUIClient, completions: ChatCompletionsClient,
         chat: OWChatSummary?, models: [OWModel], defaultModel: String?,
         mode: ChatMode = .server, localStore: LocalChatStore,
         initialToolIDs: Set<String> = []) {
        self.client = client
        self.completions = completions
        self.localStore = localStore
        self.models = models
        self.mode = mode
        self.chatID = chat?.id
        self.title = chat?.title ?? Self.placeholderTitle(mode)
        self.selectedModel = defaultModel
        self.selectedToolIDs = initialToolIDs
    }

    private static func placeholderTitle(_ m: ChatMode) -> String {
        m == .temporary ? L("Conversa temporária") : L("Nova conversa")
    }

    var isNewChat: Bool { chatID == nil }

    /// Mode can only change before the conversation has started — once there are
    /// messages (or it's been saved), switching would strand or drop history.
    var canChangeMode: Bool { chatID == nil && messages.isEmpty && !isStreaming }

    func setMode(_ m: ChatMode) {
        guard canChangeMode, m != mode else { return }
        mode = m
        title = Self.placeholderTitle(m)   // keep the placeholder in sync
    }

    var selectedModelName: String {
        guard let id = selectedModel else { return L("Selecionar modelo") }
        return models.first { $0.id == id }?.shortName ?? id
    }

    func selectModel(_ id: String) { selectedModel = id }

    // MARK: - History

    /// Loads history once, in a Task owned by the view model (not a SwiftUI
    /// `.task`, which gets cancelled mid-navigation and blanks the messages).
    func loadHistoryIfNeeded() {
        guard chatID != nil, !historyLoaded, historyTask == nil else { return }
        runHistoryLoad()
    }

    func reloadHistory() async {
        historyTask?.cancel(); historyLoaded = false
        runHistoryLoad()
        await historyTask?.value
    }

    private func runHistoryLoad() {
        guard let id = chatID else { return }
        // Local chats read straight from SwiftData — no network, no async.
        if mode == .local {
            messages = localStore.messages(id: id)
            if let m = localStore.chat(id: id)?.modelID { selectedModel = m }
            historyLoaded = true
            return
        }
        isLoadingHistory = true
        historyTask = Task { @MainActor in
            defer { self.isLoadingHistory = false; self.historyTask = nil }
            do {
                let chat = try await self.client.chat(id)
                self.messages = chat.messages
                if let m = chat.models.first { self.selectedModel = m }
                if !chat.title.isEmpty { self.title = chat.title }
                self.historyLoaded = true
            } catch is CancellationError {
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    // MARK: - Sending

    /// Stage images (raw data) for the next message — downscaled to data: URLs.
    func addImageData(_ datas: [Data]) {
        for d in datas {
            if let url = AttachImage.dataURL(from: d) { pendingImageURLs.append(url) }
        }
    }

    func removePendingImage(_ url: String) { pendingImageURLs.removeAll { $0 == url } }
    func removePendingDocument(_ att: OWAttachment) { pendingDocuments.removeAll { $0.id == att.id } }

    /// Upload raw data and stage it as a document attachment.
    private func uploadAndAttach(_ data: Data, filename: String, mime: String, displayName: String? = nil) async {
        uploading = true; defer { uploading = false }
        do {
            let f = try await client.uploadFile(data: data, filename: filename, mime: mime)
            pendingDocuments.append(OWAttachment(type: "file", id: f.id, name: displayName ?? f.filename))
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func addDocument(data: Data, filename: String, mime: String) async {
        await uploadAndAttach(data, filename: filename, mime: mime)
    }

    /// Attach a note's markdown as a document (RAG).
    func attachNote(_ note: OWNote) async {
        let md = "# \(note.title)\n\n\(note.markdown)"
        await uploadAndAttach(Data(md.utf8), filename: "nota.md", mime: "text/markdown", displayName: note.title)
    }

    /// Attach another chat's transcript as a document (RAG).
    func attachChatReference(_ summary: OWChatSummary) async {
        uploading = true; defer { uploading = false }
        do {
            let chat = try await client.chat(summary.id)
            let transcript = chat.messages.map { "\($0.role.rawValue): \($0.content)" }.joined(separator: "\n\n")
            let f = try await client.uploadFile(data: Data(transcript.utf8),
                                                filename: "conversa.txt", mime: "text/plain")
            pendingDocuments.append(OWAttachment(type: "file", id: f.id, name: summary.title))
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Process a web page server-side and attach its content (RAG).
    func attachWebPage(_ urlString: String) async {
        let url = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        uploading = true; defer { uploading = false }
        do {
            let (name, content) = try await client.processWebPage(url: url)
            guard !content.isEmpty else { self.error = L("Não foi possível ler a página."); return }
            await uploadAndAttach(Data(content.utf8), filename: "pagina.txt", mime: "text/plain", displayName: name)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Attach a knowledge base (collection) by reference — RAG over its documents.
    func attachKnowledge(_ kb: OWNamedItem) {
        pendingDocuments.append(OWAttachment(type: "collection", id: kb.id, name: kb.name))
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = pendingImageURLs
        let docs = pendingDocuments
        guard (!text.isEmpty || !images.isEmpty || !docs.isEmpty), !isStreaming, let model = selectedModel else { return }
        input = ""; pendingImageURLs = []; pendingDocuments = []; error = nil

        messages.append(OWMessage(role: .user, content: text,
                                  timestamp: Date().timeIntervalSince1970,
                                  imageURLs: images, documents: docs))
        let assistant = OWMessage(role: .assistant, content: "", model: model)
        messages.append(assistant)
        isStreaming = true

        // Context = everything except the empty assistant placeholder we stream into.
        var convo = messages.dropLast().map { OWChatMessageInput($0) }
        // Only the CURRENT (last) message keeps its images. Re-sending historical
        // images on every turn breaks non-vision models with "No endpoints found
        // that support image input" (the web client doesn't re-send them either).
        if convo.count > 1 {
            for i in convo.indices.dropLast() { convo[i].imageURLs = [] }
        }
        // Ambient context (date/time, location, custom instructions) goes first.
        if let ctx = contextProvider?() { convo.insert(ctx, at: 0) }
        // Server chats stream token-by-token over the socket; local/temporary chats
        // (no server chat id) use the buffered SSE path.
        if mode == .server {
            streamTask = Task { await self.runSocketTurn(model: model, convo: convo, files: docs, assistant: assistant) }
        } else {
            streamTask = Task { await self.runStream(model: model, convo: convo, files: docs, assistantID: assistant.id) }
        }
    }

    /// True token streaming via the socket flow (server chats). Ensures the chat +
    /// empty assistant message exist server-side (so events route by id), then
    /// consumes cumulative content + tool status. Falls back to buffered SSE if the
    /// chat can't be prepared.
    private func runSocketTurn(model: String, convo: [OWChatMessageInput],
                               files: [OWAttachment], assistant: OWMessage) async {
        do {
            let title = chatTitle()
            if let id = chatID {
                try await client.updateChat(id: id, title: title, model: model, messages: messages)
            } else {
                let id = try await client.createChat(title: title, model: model, messages: messages)
                chatID = id; self.title = title
            }
        } catch is CancellationError {
            isStreaming = false; return
        } catch {
            await runStream(model: model, convo: convo, files: files, assistantID: assistant.id)
            return
        }
        guard let chatID else {
            await runStream(model: model, convo: convo, files: files, assistantID: assistant.id); return
        }

        var sawContent = false
        let options = OWStreamOptions(webSearch: webSearch, imageGeneration: imageGeneration,
                                      codeInterpreter: codeInterpreter, toolIDs: Array(selectedToolIDs))
        for await update in client.socketStream(chatID: chatID, messageID: assistant.id,
                                                model: model, messages: convo, files: files, options: options) {
            if Task.isCancelled { break }
            switch update {
            case .content(let full):
                sawContent = true
                setContent(assistant.id, full)   // cumulative → replace, not append
            case .status(let s):
                toolStatus = s
            case .done:
                break
            case .error(let msg):
                let m = friendlyError(msg)
                if let i = index(of: assistant.id), messages[i].content.isEmpty { messages[i].content = "⚠️ \(m)" }
                else { self.error = m }
            }
        }
        toolStatus = nil
        isStreaming = false
        if !sawContent, let i = index(of: assistant.id), messages[i].content.isEmpty {
            messages[i].content = L("_(sem resposta)_")
        }
        // The socket flow already persisted the reply server-side; just refresh.
        onChanged?()
    }

    /// Image-generation turn: the prompt goes to the server's image engine
    /// (ComfyUI/Automatic1111/etc., whatever Open WebUI is configured with) and
    /// the result is inserted as an assistant image message, ChatGPT-style.
    /// `model: nil` lets the server use its default image model.
    func generateImage() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        input = ""; error = nil

        messages.append(OWMessage(role: .user, content: text, timestamp: Date().timeIntervalSince1970))
        // No model tag on the reply — the header would otherwise show an LLM name
        // that had nothing to do with the image engine.
        let assistant = OWMessage(role: .assistant, content: "")
        messages.append(assistant)
        isStreaming = true
        streamTask = Task { await self.runImageGen(prompt: text, assistantID: assistant.id) }
    }

    private func runImageGen(prompt: String, assistantID: String) async {
        do {
            let urls = try await client.generateImages(OWImageRequest(prompt: prompt))
            guard let i = index(of: assistantID) else { return }
            if urls.isEmpty {
                messages[i].content = L("Não foi possível gerar a imagem.")
            } else {
                messages[i].imageURLs = urls
            }
        } catch is CancellationError {
        } catch {
            let msg = friendlyError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            if let i = index(of: assistantID) { messages[i].content = "⚠️ \(msg)" }
        }
        isStreaming = false
        await persist()
    }

    private func runStream(model: String, convo: [OWChatMessageInput],
                           files: [OWAttachment], assistantID: String) async {
        var sawText = false
        do {
            for try await update in completions.stream(model: model, messages: convo, files: files,
                                                       options: OWStreamOptions(webSearch: webSearch,
                                                                                imageGeneration: imageGeneration,
                                                                                codeInterpreter: codeInterpreter,
                                                                                toolIDs: Array(selectedToolIDs))) {
                switch update {
                case .textDelta(let d):
                    sawText = true
                    append(assistantID, d)
                case .reasoningDelta(let d):
                    appendReasoning(assistantID, d)
                case .error(let msg):
                    setContent(assistantID, friendlyError(msg))
                case .done:
                    break
                }
            }
            if !sawText, let i = index(of: assistantID), messages[i].content.isEmpty {
                messages[i].content = L("_(sem resposta)_")
            }
        } catch is CancellationError {
            // user stopped — keep whatever streamed so far
        } catch {
            let msg = friendlyError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            if let i = index(of: assistantID), messages[i].content.isEmpty {
                messages[i].content = "⚠️ \(msg)"
            } else {
                self.error = msg
            }
        }
        isStreaming = false
        await persist()
    }

    /// Map raw server errors to clearer pt-BR messages.
    private func friendlyError(_ msg: String) -> String {
        let l = msg.lowercased()
        if l.contains("image input") || l.contains("support image") || l.contains("no endpoints found that support image") {
            return L("Este modelo não tem visão (não aceita imagens). Escolha um modelo com visão para enviar imagens.")
        }
        return msg
    }

    /// Persists the conversation per its mode: temporary → nothing, local →
    /// on-device SwiftData, server → Open WebUI.
    private func persist() async {
        guard mode != .temporary else { return }   // ephemeral — never saved
        guard !messages.isEmpty, let model = selectedModel else { return }
        let title = chatTitle()

        if mode == .local {
            // On-device only — never touches the server/account database.
            let id = localStore.save(id: chatID, title: title, modelID: model, messages: messages)
            if chatID == nil { chatID = id; self.title = title }
            onChanged?()
            return
        }

        do {
            if let id = chatID {
                // updateChat REPLACES the whole chat server-side. If the web UI
                // added messages meanwhile (e.g. image generations), writing our
                // stale local array would erase them — so merge first: adopt the
                // fuller server history and re-append what only exists locally.
                if let server = try? await client.chat(id), server.messages.count > 0 {
                    let known = Set(server.messages.map(\.id))
                    let localOnly = messages.filter { !known.contains($0.id) }
                    if server.messages.count > messages.count - localOnly.count {
                        messages = server.messages + localOnly
                    }
                }
                try await client.updateChat(id: id, title: title, model: model, messages: messages)
            } else {
                let id = try await client.createChat(title: title, model: model, messages: messages)
                chatID = id
                self.title = title
            }
            onChanged?()
        } catch {
            // Non-fatal: the conversation stays on screen even if the save fails.
        }
    }

    private func chatTitle() -> String {
        if chatID != nil { return title }   // keep an existing chat's title
        if let first = messages.first(where: { $0.role == .user })?.content, !first.isEmpty {
            return String(first.prefix(50))
        }
        return title
    }

    func stop() {
        streamTask?.cancel()
        isStreaming = false
    }

    /// Merge turns produced by a voice session into this chat, then persist per
    /// mode. Voice is seeded from our messages, so only genuinely new turns are
    /// appended (keeps image/doc attachments on the originals intact). This is
    /// what makes a voice conversation carry over into the typed thread and share
    /// context both ways.
    func ingestVoiceTurns(_ voiceMessages: [OWMessage]) {
        let known = Set(messages.map(\.id))
        let fresh = voiceMessages.filter { !known.contains($0.id) && !$0.content.isEmpty }
        guard !fresh.isEmpty else { return }
        messages.append(contentsOf: fresh)
        // Serialize persists: voice can commit turns back-to-back, and two
        // concurrent first-turn saves would each createChat → duplicate chats.
        let prev = persistChain
        persistChain = Task { await prev?.value; await persist(); onChanged?() }
    }
    private var persistChain: Task<Void, Never>?

    // MARK: - Mutation helpers

    private func index(of id: String) -> Int? { messages.firstIndex { $0.id == id } }
    private func append(_ id: String, _ text: String) {
        if let i = index(of: id) { messages[i].content += text }
    }
    /// Seeds `reasoning` on the first delta (nil → "") so the disclosure appears
    /// as soon as the model starts thinking, before any text arrives.
    private func appendReasoning(_ id: String, _ text: String) {
        guard let i = index(of: id) else { return }
        messages[i].reasoning = (messages[i].reasoning ?? "") + text
    }
    private func setContent(_ id: String, _ text: String) {
        if let i = index(of: id) { messages[i].content = text }
    }
}
