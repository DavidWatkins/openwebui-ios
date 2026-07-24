import SwiftUI
import OpenWebUIKit
#if canImport(UIKit)
import UIKit
#endif

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
    /// Composer tool toggles: independent client-side tools run via the agent loop
    /// (prompt-based tool calling on a raw model — no server pipe, no native FC).
    /// Each is a real tool the model can choose to call. Persisted so a chosen set
    /// stays on by default across chats + launches (Claude-style).
    @Published var searchTool = UserDefaults.standard.bool(forKey: "tool.search") {
        didSet { UserDefaults.standard.set(searchTool, forKey: "tool.search") }
    }
    @Published var weatherTool = UserDefaults.standard.bool(forKey: "tool.weather") {
        didSet { UserDefaults.standard.set(weatherTool, forKey: "tool.weather") }
    }
    /// Composer toggle: the next prompt generates an image (server image engine)
    /// instead of a chat reply.
    @Published var imageMode = false
    /// Server tool/function ids enabled for the next reply. Retained for the socket
    /// path's plumbing; no UI selects them now that tools run client-side.
    @Published var selectedToolIDs: Set<String> = []
    /// Any client-side agent tool on → route the turn through the agent loop.
    var agentToolsOn: Bool { searchTool || weatherTool }
    /// The enabled client-side tools, as the ids the tool doc / parser use.
    var enabledAgentTools: [String] {
        (searchTool ? ["web_search"] : []) + (weatherTool ? ["weather"] : [])
    }
    /// Live tool-progress line from the socket flow (e.g. "🔧 weather: Boston").
    @Published var toolStatus: String?
    /// Open WebUI per-turn feature flags (server generates an image from the reply /
    /// runs code). Distinct from `imageMode`, which is the manual image composer.
    /// Persisted alongside the client tools so the chosen set is the default.
    @Published var imageGeneration = UserDefaults.standard.bool(forKey: "tool.image") {
        didSet { UserDefaults.standard.set(imageGeneration, forKey: "tool.image") }
    }
    @Published var codeInterpreter = UserDefaults.standard.bool(forKey: "tool.code") {
        didSet { UserDefaults.standard.set(codeInterpreter, forKey: "tool.code") }
    }
    /// Whether the model may think (emit a `<think>` block). OFF → answer directly.
    /// Persisted; defaults ON (nil-coalesced so a fresh install starts with thinking).
    @Published var thinkingEnabled = (UserDefaults.standard.object(forKey: "tool.thinking") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(thinkingEnabled, forKey: "tool.thinking") }
    }
    /// Generation speed (tokens/sec) per assistant message id, measured while it
    /// streamed. Only set when a reply actually streamed over time (not for a
    /// buffered pipe reply that arrives all at once).
    @Published var genRate: [String: Double] = [:]

    let models: [OWModel]

    /// Where this chat's history lives: server / on-device / ephemeral.
    /// Changeable via the mode control, but only while the chat is still empty.
    @Published private(set) var mode: ChatMode

    /// nil until the conversation is persisted (new chat). For `.local` chats
    /// this is the on-device id; for `.server` chats, the server id.
    private(set) var chatID: String?
    /// Fired after a turn finishes so the list can refresh.
    var onChanged: (() -> Void)?
    /// Fired after a reply completes with (last user text, reply text) — drives
    /// cross-chat memory extraction.
    var onReplyComplete: ((String, String) -> Void)?
    /// Supplies the ambient-context system message (date/time, location, custom
    /// instructions) to prepend to each turn. Evaluated per-send so it stays live.
    var contextProvider: (() -> OWChatMessageInput?)?

    private let client: OpenWebUIClient
    private let completions: ChatCompletionsClient
    private let localStore: LocalChatStore
    private var streamTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private var historyLoaded = false

    // MARK: - Branching history
    // The full message tree (id → node), the source of truth for structure. The
    // rendered `messages` array is the active branch (currentLeafId → root). Edit/
    // regenerate/retry add sibling nodes and move the leaf; nothing is deleted, so
    // branches (incl. web-UI ones) survive. `messages` holds the streamed content
    // for the active branch; `syncBranchIntoTree()` folds it back before persisting.
    private var tree: [String: OWMessage] = [:]
    private var currentLeafId: String?

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

    /// A raw LLM (not a server-side pipe like the Agent tools or Arena). Raw models
    /// get native function calling so they can autonomously call their bound tools.
    static func isRawModel(_ id: String) -> Bool {
        let l = id.lowercased()
        return !l.hasPrefix("agent") && !l.hasSuffix(".agent") && !l.contains("arena")
    }

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
            seedTreeFromMessages()
            if let m = localStore.chat(id: id)?.modelID { selectedModel = m }
            historyLoaded = true
            return
        }
        isLoadingHistory = true
        historyTask = Task { @MainActor in
            defer { self.isLoadingHistory = false; self.historyTask = nil }
            do {
                let chat = try await self.client.chat(id)
                self.loadTree(from: chat)
                if let m = chat.models.first { self.selectedModel = m }
                if !chat.title.isEmpty { self.title = chat.title }
                self.localStore.cacheChat(chat)   // keep the offline copy fresh
                self.historyLoaded = true
            } catch is CancellationError {
            } catch {
                // Offline / server error: fall back to the cached copy if we have one.
                if let cached = self.localStore.cachedChat(id: id) {
                    self.loadTree(from: cached)
                    if let m = cached.models.first { self.selectedModel = m }
                    if !cached.title.isEmpty { self.title = cached.title }
                    self.historyLoaded = true
                } else {
                    self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
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

    /// Apply content shared in from another app (Share Extension): a URL fetches
    /// the page for RAG, text prefills the composer, a file is uploaded + attached.
    func applyShared(_ item: SharedItem) async {
        switch item.kind {
        case .url:
            if let t = item.text, !t.isEmpty { await attachWebPage(t) }
        case .text:
            if let t = item.text, !t.isEmpty { input = t }
        case .file:
            if let name = item.fileName, let data = SharedInbox.readFile(name) {
                await addDocument(data: data, filename: item.displayName ?? name,
                                  mime: item.mime ?? "application/octet-stream")
                SharedInbox.removeFile(name)
            }
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

        let now = Date().timeIntervalSince1970
        var user = OWMessage(role: .user, content: text, timestamp: now,
                             imageURLs: images, documents: docs)
        user.parentId = currentLeafId
        var assistant = OWMessage(role: .assistant, content: "", model: model, timestamp: now + 0.001)
        assistant.parentId = user.id
        tree[user.id] = user
        tree[assistant.id] = assistant
        currentLeafId = assistant.id
        rebuildActiveBranch()
        startAssistantTurn(model: model, assistantID: assistant.id)
    }

    /// Builds the context, then streams into the (already-created, empty) assistant
    /// node at the active leaf. Shared by send / regenerate / retry / edit.
    private func startAssistantTurn(model: String, assistantID: String) {
        guard let assistant = tree[assistantID] else { return }
        isStreaming = true
        toolStatus = nil
        // Context = the active branch except the empty assistant we stream into.
        var convo = messages.dropLast().map { OWChatMessageInput($0) }
        // Only the CURRENT (last) message keeps its images. Re-sending historical
        // images on every turn breaks non-vision models with "No endpoints found
        // that support image input" (the web client doesn't re-send them either).
        if convo.count > 1 {
            for i in convo.indices.dropLast() { convo[i].imageURLs = [] }
        }
        // Ambient context (date/time, location, custom instructions) goes first.
        if let ctx = contextProvider?() { convo.insert(ctx, at: 0) }
        let files = messages.last(where: { $0.role == .user })?.documents ?? []
        // Tools on a raw model → run the client-side agent loop (prompt-based tool
        // calling, no server pipe / native FC). Otherwise a normal turn.
        if agentToolsOn, Self.isRawModel(model) {
            streamTask = Task { await self.runAgentTurn(model: model, convo: convo, assistantID: assistantID) }
        } else if mode == .server {
            streamTask = Task { await self.runSocketTurn(model: model, convo: convo, files: files, assistant: assistant) }
        } else {
            streamTask = Task { await self.runStream(model: model, convo: convo, files: files, assistantID: assistantID) }
        }
    }

    /// True token streaming via the socket flow (server chats). Ensures the chat +
    /// empty assistant message exist server-side (so events route by id), then
    /// consumes cumulative content + tool status. Falls back to buffered SSE if the
    /// chat can't be prepared.
    private func runSocketTurn(model: String, convo: [OWChatMessageInput],
                               files: [OWAttachment], assistant: OWMessage) async {
        let isNewChat = chatID == nil
        do {
            try await persistTree()
        } catch is CancellationError {
            isStreaming = false; return
        } catch {
            await runStream(model: model, convo: convo, files: files, assistantID: assistant.id)
            return
        }
        guard let chatID else {
            await runStream(model: model, convo: convo, files: files, assistantID: assistant.id); return
        }

        // Keep the app alive briefly if it's backgrounded mid-reply so we can catch
        // the finish and post a local notification. The reply persists server-side
        // regardless, so if the window expires the answer is still safe on reload.
        beginBackgroundHold()
        defer { endBackgroundHold() }

        var sawContent = false
        // Live tok/s: clock starts at the first token (reasoning or content) and the
        // rate counts reasoning + answer. Local counters mirror the cumulative
        // frames so the flush-driven tick doesn't have to re-read `messages`.
        var genStart: Date?
        var contentChars = 0, reasonChars = 0
        streamTick = { [weak self] in
            guard let self, let s = genStart else { return }
            self.tickRate(assistant.id, chars: contentChars + reasonChars, start: s)
        }
        let options = OWStreamOptions(webSearch: false, imageGeneration: imageGeneration,
                                      codeInterpreter: codeInterpreter, toolIDs: Array(selectedToolIDs),
                                      enableThinking: thinkingEnabled)
        for await update in client.socketStream(chatID: chatID, messageID: assistant.id,
                                                model: model, messages: convo, files: files, options: options) {
            if Task.isCancelled { break }
            switch update {
            case .content(let full):
                sawContent = true
                toolStatus = nil                   // answer is arriving → tools are done
                contentChars = full.count
                queueContent(assistant.id, full)   // cumulative → replace, not append
                if genStart == nil { genStart = Date() }
            case .reasoning(let full):
                reasonChars = full.count
                queueReasoning(assistant.id, full) // cumulative → replace, not append
                if genStart == nil { genStart = Date() }
            case .toolUse(let t):
                toolStatus = nil                 // the run finished → drop the spinner
                addToolUse(assistant.id, t)
            case .status(let s):
                toolStatus = s
            case .done:
                break
            case .error(let msg):
                finishStreamUI()   // land anything queued before placing the error
                let m = friendlyError(msg)
                if let i = index(of: assistant.id), messages[i].content.isEmpty { messages[i].content = "⚠️ \(m)" }
                else { self.error = m }
            }
        }
        finishStreamUI()   // guaranteed final flush — the last frame always lands
        // A buffered pipe reply (the Agent) runs its whole tool + reasoning loop
        // server-side and writes the answer only at the very end — often AFTER the
        // socket stream has already closed. If we caught no content, the reply is
        // still being written server-side; poll for it briefly instead of giving up
        // (a single immediate re-fetch usually lands before the pipe finishes).
        if !sawContent, !Task.isCancelled {
            toolStatus = L("Finalizando resposta…")
            for _ in 0..<16 {                       // ~24s at 1.5s intervals
                if Task.isCancelled { break }
                if let server = try? await client.chat(chatID),
                   let node = server.allMessages.first(where: { $0.id == assistant.id }),
                   !node.content.isEmpty {
                    setContent(assistant.id, node.content)
                    if let r = node.reasoning { setReasoning(assistant.id, r) }
                    sawContent = true
                    break
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        toolStatus = nil
        isStreaming = false
        if !sawContent, let i = index(of: assistant.id), messages[i].content.isEmpty {
            messages[i].content = L("_(sem resposta)_")
        }
        notifyReplyIfBackgrounded(assistant.id)
        // OWUI stores a socket reply with an empty `content` (the text lives in its
        // `output` block), so on reload it comes back blank. Re-write the tree with
        // the streamed text folded in so the reply survives a refetch.
        if sawContent { await persist() } else { onChanged?() }
        if sawContent, let reply = messages.first(where: { $0.id == assistant.id })?.content {
            let lastUser = messages.last { $0.role == .user }?.content ?? ""
            onReplyComplete?(lastUser, reply)
        }
        if isNewChat, sawContent { await autoTitle(assistantID: assistant.id) }
    }

    /// Image-generation turn: the prompt goes to the server's image engine
    /// (ComfyUI/Automatic1111/etc., whatever Open WebUI is configured with) and
    /// the result is inserted as an assistant image message, ChatGPT-style.
    /// `model: nil` lets the server use its default image model.
    func generateImage() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        input = ""; error = nil

        let now = Date().timeIntervalSince1970
        var user = OWMessage(role: .user, content: text, timestamp: now)
        user.parentId = currentLeafId
        // No model tag on the reply — the header would otherwise show an LLM name
        // that had nothing to do with the image engine.
        var assistant = OWMessage(role: .assistant, content: "", timestamp: now + 0.001)
        assistant.parentId = user.id
        tree[user.id] = user
        tree[assistant.id] = assistant
        currentLeafId = assistant.id
        rebuildActiveBranch()
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
        // Deltas accumulate into local buffers; the throttle publishes the latest
        // full text so `messages` isn't republished per token.
        var text = "", reason = ""
        var genStart: Date?, genChars = 0
        streamTick = { [weak self] in
            guard let self, let s = genStart else { return }
            self.tickRate(assistantID, chars: genChars, start: s)
        }
        do {
            for try await update in completions.stream(model: model, messages: convo, files: files,
                                                       options: OWStreamOptions(webSearch: false,
                                                                                imageGeneration: imageGeneration,
                                                                                codeInterpreter: codeInterpreter,
                                                                                toolIDs: Array(selectedToolIDs),
                                                                                enableThinking: thinkingEnabled)) {
                switch update {
                case .textDelta(let d):
                    sawText = true
                    if genStart == nil { genStart = Date() }
                    genChars += d.count
                    text += d
                    queueContent(assistantID, text)
                case .reasoningDelta(let d):
                    if genStart == nil { genStart = Date() }
                    genChars += d.count
                    reason += d
                    queueReasoning(assistantID, reason)
                case .error(let msg):
                    queueContent(assistantID, friendlyError(msg))
                case .done:
                    break
                }
            }
            finishStreamUI()
            if !sawText, let i = index(of: assistantID), messages[i].content.isEmpty {
                messages[i].content = L("_(sem resposta)_")
            }
        } catch is CancellationError {
            finishStreamUI()   // user stopped — keep whatever streamed so far
        } catch {
            finishStreamUI()
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

    // MARK: - Client-side agent loop (tools without a server pipe)

    /// Prompt-based tool calling run entirely on the client: give a raw model a
    /// tool doc, let it emit a JSON tool call, run the tool here (web search via
    /// Open WebUI's search API, weather via Open-Meteo), feed the result back, and
    /// loop until it answers. Mirrors the server pipe's logic but needs no pipe and
    /// no native function calling (which is unreliable on some models).
    private func runAgentTurn(model: String, convo baseConvo: [OWChatMessageInput], assistantID: String) async {
        let tools = enabledAgentTools
        var convo: [OWChatMessageInput] = [OWChatMessageInput(role: "system", text: Self.toolDoc(for: tools))] + baseConvo
        var reasonings: [String] = []
        var genStart: Date?, genChars = 0
        let maxIterations = 5
        streamTick = { [weak self] in
            guard let self, let s = genStart else { return }
            self.tickRate(assistantID, chars: genChars, start: s)
        }

        do {
            for _ in 0..<maxIterations {
                if Task.isCancelled { break }
                var step = "", stepReason = ""
                var streamingAnswer = false   // once we know it's prose, stream live

                for try await update in completions.stream(model: model, messages: convo, files: [],
                                                           options: OWStreamOptions(temperature: nil,
                                                                                    enableThinking: thinkingEnabled)) {
                    if Task.isCancelled { break }
                    switch update {
                    case .textDelta(let d):
                        step += d
                        // Decide once, early: a tool call starts with `{`; anything
                        // else is the final answer → stream it into the bubble live.
                        if !streamingAnswer, !step.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"),
                           !step.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            streamingAnswer = true
                        }
                        if streamingAnswer {
                            toolStatus = nil; queueContent(assistantID, step)
                            if genStart == nil { genStart = Date() }
                            genChars += d.count
                        } else { toolStatus = L("Pensando…") }
                    case .reasoningDelta(let d):
                        stepReason += d; queueReasoning(assistantID, stepReason)
                        if genStart == nil { genStart = Date() }
                        genChars += d.count
                    case .error(let msg):
                        finishStreamUI()
                        setContent(assistantID, friendlyError(msg)); toolStatus = nil; isStreaming = false
                        await persist(); return
                    case .done: break
                    }
                }
                if !stepReason.isEmpty { reasonings.append(stepReason) }

                guard let call = Self.parseToolCall(step), tools.contains(call.tool) else {
                    // No (enabled) tool call → `step` is the final answer (streamed).
                    break
                }
                // Run the tool, show a card, feed the result back, loop.
                toolStatus = "🔧 \(call.tool): \(call.argument)"
                let result = await runTool(call)
                addToolUse(assistantID, OWToolUse(action: call.tool == "weather" ? "weather" : "web_search",
                                                  query: call.argument, results: result.text, sources: result.sources))
                convo.append(OWChatMessageInput(role: "assistant", text: step))
                convo.append(OWChatMessageInput(role: "user",
                    text: "Tool result:\n\(result.text)\n\nUsing this, answer my previous question directly. Do not output JSON or call another tool unless truly necessary."))
                flushStreamUI()               // nothing queued may land after the clear
                setContent(assistantID, "")   // clear any stray partial before the next step
            }
            finishStreamUI()
        } catch is CancellationError {
            finishStreamUI()   // keep whatever streamed so far
        } catch {
            finishStreamUI()
            let msg = friendlyError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            if let i = index(of: assistantID), messages[i].content.isEmpty { messages[i].content = "⚠️ \(msg)" }
            else { self.error = msg }
        }

        toolStatus = nil
        isStreaming = false
        // Combine the thinking from every step (tool-deciding + answer) for the
        // reasoning disclosure, so the whole chain is auditable.
        if !reasonings.isEmpty { setReasoning(assistantID, reasonings.joined(separator: "\n\n---\n\n")) }
        if let i = index(of: assistantID), messages[i].content.isEmpty {
            messages[i].content = L("_(sem resposta)_")
        }
        let isNew = isNewChat
        await persist()
        if let reply = messages.first(where: { $0.id == assistantID })?.content, !reply.isEmpty {
            onReplyComplete?(messages.last { $0.role == .user }?.content ?? "", reply)
        }
        if isNew { await autoTitle(assistantID: assistantID) }
    }

    /// Executes one parsed tool call.
    private func runTool(_ call: (tool: String, argument: String)) async -> OWToolResult {
        switch call.tool {
        case "weather": return await runWeatherTool(location: call.argument)
        default:        return await client.runWebSearchTool(query: call.argument)
        }
    }

    /// Parses a `{"tool":"web_search","query":"…"}` / `{"tool":"weather","location":"…"}`
    /// call out of the model's reply. Returns nil when the reply is a direct answer.
    static func parseToolCall(_ text: String) -> (tool: String, argument: String)? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = t.firstIndex(of: "{"), let end = t.lastIndex(of: "}") else { return nil }
        let json = String(t[start...end])
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let tool = obj["tool"] as? String else { return nil }
        let arg = (obj["query"] as? String) ?? (obj["location"] as? String) ?? ""
        guard tool == "web_search" || tool == "weather" else { return nil }
        return (tool, arg)
    }

    /// The tool doc handed to the model — mirrors the server pipe's contract, but
    /// only advertises the tools the user actually enabled (each is independent).
    static func toolDoc(for tools: [String]) -> String {
        var calls: [String] = [], rules: [String] = []
        if tools.contains("web_search") {
            calls.append(#"- Web search: {"tool": "web_search", "query": "<search terms>"}"#)
            rules.append("- For current events, news, recent releases, prices, or verifying a fact → ALWAYS call web_search first.")
        }
        if tools.contains("weather") {
            calls.append(#"- Weather:    {"tool": "weather", "location": "<place>"}"#)
            rules.append("- For weather/temperature/forecast anywhere → call weather. You DO have live weather; never say you can't.")
        }
        rules.append("- Use ONE tool at a time. After you get a tool result, answer the user's question directly in prose — do NOT output JSON again unless you truly need another tool.")
        rules.append("- For general knowledge, coding, math, or creative writing, just answer directly (no tool).")
        return """
        You have live tools and MUST use them for anything current, real-time, or fact-based you're unsure of. To call a tool, reply with ONLY a JSON object and nothing else:
        \(calls.joined(separator: "\n"))
        Rules:
        \(rules.joined(separator: "\n"))
        """
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
            try await persistTree()
            onChanged?()
        } catch {
            // Non-fatal: the conversation stays on screen even if the save fails.
        }
    }

    /// Tree-preserving server write. Folds the streamed active-branch content back
    /// into the tree, adopts any nodes the web UI added since we loaded (so we don't
    /// clobber them), then writes the whole tree with the current leaf.
    private func persistTree() async throws {
        syncBranchIntoTree()
        let title = chatTitle()
        let models = [selectedModel].compactMap { $0 }
        if let id = chatID {
            if let server = try? await client.chat(id) {
                for n in server.allMessages where tree[n.id] == nil { tree[n.id] = n }
            }
            try await client.updateChatTree(id: id, title: title, models: models,
                                            tree: Array(tree.values), currentId: currentLeafId)
        } else {
            let id = try await client.createChatTree(title: title, models: models,
                                                     tree: Array(tree.values), currentId: currentLeafId)
            chatID = id; self.title = title
        }
        // Keep the offline cache in step with what we just wrote.
        if mode == .server, let id = chatID {
            localStore.cacheChat(OWChat(id: id, title: chatTitle(), models: models,
                                        allMessages: Array(tree.values), currentId: currentLeafId))
        }
    }

    private func chatTitle() -> String {
        if chatID != nil { return title }   // keep an existing chat's title
        if let first = messages.first(where: { $0.role == .user })?.content, !first.isEmpty {
            return String(first.prefix(50))
        }
        return title
    }

    /// After a new chat's first reply, replace the truncated placeholder with a
    /// short LLM-generated title (like the web UI / Claude). Best-effort: on any
    /// failure the first-message title stays. Runs only for server chats.
    private func autoTitle(assistantID: String) async {
        guard let id = chatID, mode == .server else { return }
        let user = messages.first { $0.role == .user }?.content ?? ""
        let reply = messages.first { $0.id == assistantID }?.content ?? ""
        guard !user.isEmpty else { return }
        let convo = "User: \(user.prefix(600))\nAssistant: \(reply.prefix(600))"
        guard let model = titleModel(),
              let generated = await client.generateTitle(model: model, conversation: convo),
              !Task.isCancelled else { return }
        title = generated
        try? await client.renameChat(id: id, title: generated)
        onChanged?()
    }

    /// A base (non-pipe) model for the title call — the agent pipe would run its
    /// whole tool loop just to name a chat. Prefer the chat's own model if it's a
    /// base model, else the first non-`agent` model the server offers.
    private func titleModel() -> String? {
        if let m = selectedModel, !m.hasPrefix("agent") { return m }
        return models.first { !$0.id.hasPrefix("agent") }?.id
    }

    // MARK: - Branching operations

    /// Regenerate an assistant reply as a new sibling branch (the old one is kept).
    /// `model` nil = reuse the reply's model; non-nil = "retry with a different model".
    func regenerate(messageID: String, model: String? = nil) {
        guard !isStreaming, let node = tree[messageID], node.role == .assistant else { return }
        guard let mdl = model ?? node.model ?? selectedModel else { return }
        var reply = OWMessage(role: .assistant, content: "", model: mdl,
                              timestamp: Date().timeIntervalSince1970)
        reply.parentId = node.parentId
        tree[reply.id] = reply
        currentLeafId = reply.id
        if model != nil { selectedModel = mdl }   // reflect the retry model in the picker
        rebuildActiveBranch()
        startAssistantTurn(model: mdl, assistantID: reply.id)
    }

    /// Edit a user message: forks a new user node (new content) + fresh reply as a
    /// sibling branch, so the original question and its answer are preserved.
    func editUser(messageID: String, newText: String) {
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isStreaming, !text.isEmpty,
              let node = tree[messageID], node.role == .user,
              let model = selectedModel else { return }
        let now = Date().timeIntervalSince1970
        var user = OWMessage(role: .user, content: text, timestamp: now,
                             imageURLs: node.imageURLs, documents: node.documents)
        user.parentId = node.parentId
        var reply = OWMessage(role: .assistant, content: "", model: model, timestamp: now + 0.001)
        reply.parentId = user.id
        tree[user.id] = user
        tree[reply.id] = reply
        currentLeafId = reply.id
        rebuildActiveBranch()
        startAssistantTurn(model: model, assistantID: reply.id)
    }

    /// Switch the visible branch at a forked message (the `‹ n/m ›` control).
    func switchBranch(messageID: String, delta: Int) {
        guard !isStreaming, tree[messageID] != nil else { return }
        let sibs = siblings(of: messageID)
        guard sibs.count > 1, let idx = sibs.firstIndex(where: { $0.id == messageID }) else { return }
        let newIndex = idx + delta
        guard sibs.indices.contains(newIndex) else { return }
        currentLeafId = leaf(from: sibs[newIndex].id)
        rebuildActiveBranch()
        Task { await self.persist() }   // remember the active branch server-side
    }

    /// For the UI: this message's position among its siblings (1-based) and the
    /// sibling count, or nil when it isn't a fork point.
    func branchInfo(for messageID: String) -> (index: Int, total: Int)? {
        let sibs = siblings(of: messageID)
        guard sibs.count > 1, let idx = sibs.firstIndex(where: { $0.id == messageID }) else { return nil }
        return (idx + 1, sibs.count)
    }

    // MARK: - Tree internals

    private func loadTree(from chat: OWChat) {
        let nodes = chat.allMessages.isEmpty ? chat.messages : chat.allMessages
        tree = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        currentLeafId = chat.currentId ?? chat.messages.last?.id ?? nodes.last?.id
        rebuildActiveBranch()
        if messages.isEmpty { messages = chat.messages }   // safety net
    }

    /// Local/temporary chats arrive as a linear array — seed a trivial parent chain
    /// so in-session branching still works (resets on reload; there's no server tree).
    private func seedTreeFromMessages() {
        var parent: String?
        var map: [String: OWMessage] = [:]
        for m in messages {
            var n = m; n.parentId = parent; map[n.id] = n; parent = n.id
        }
        tree = map
        currentLeafId = messages.last?.id
    }

    private func rebuildActiveBranch() {
        guard let leaf = currentLeafId, tree[leaf] != nil else { return }
        var chain: [OWMessage] = []
        var id: String? = leaf
        var guardN = 0
        while let i = id, let m = tree[i], guardN < 10_000 { chain.append(m); id = m.parentId; guardN += 1 }
        messages = chain.reversed()
    }

    /// Fold the active branch's (streamed) content back into the tree before a write.
    private func syncBranchIntoTree() {
        for m in messages { tree[m.id] = m }
    }

    private func children(of id: String?) -> [OWMessage] {
        tree.values.filter { $0.parentId == id }.sorted { ($0.timestamp ?? 0) < ($1.timestamp ?? 0) }
    }
    private func siblings(of id: String) -> [OWMessage] {
        guard let node = tree[id] else { return [] }
        return children(of: node.parentId)
    }
    /// Walk down from a node to a leaf, always taking the newest child.
    private func leaf(from id: String) -> String {
        var cur = id, guardN = 0
        while guardN < 10_000, let next = children(of: cur).last { cur = next.id; guardN += 1 }
        return cur
    }

    func stop() {
        streamTask?.cancel()
        isStreaming = false
        // Cancel the server-side generation too: the socket flow runs as a background
        // task that would otherwise keep generating and overwrite the truncated reply
        // on reload. (No-op for local/temporary chats or before the chat is saved.)
        if mode == .server, let id = chatID {
            Task { try? await client.stopChatTasks(id) }
        }
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
        // Chain the fresh turns onto the current leaf so the branch tree stays
        // consistent (otherwise they'd persist as parentless orphans).
        syncBranchIntoTree()
        var parent = currentLeafId
        for m in fresh {
            var n = m; n.parentId = parent; tree[n.id] = n; parent = n.id
        }
        currentLeafId = parent
        rebuildActiveBranch()
        // Serialize persists: voice can commit turns back-to-back, and two
        // concurrent first-turn saves would each createChat → duplicate chats.
        let prev = persistChain
        persistChain = Task { await prev?.value; await persist(); onChanged?() }
    }
    private var persistChain: Task<Void, Never>?

    // MARK: - Stream UI throttling

    // Publishing `messages` on every token makes SwiftUI re-diff the whole
    // transcript per delta. The stream paths queue the LATEST full text here and
    // a ~40ms gate applies it, so the UI updates at most ~25×/s no matter the
    // token rate. `finishStreamUI()` is the guaranteed final flush.
    private var pendingContent: [String: String] = [:]
    private var pendingReasoning: [String: String] = [:]
    private var lastFlush = Date.distantPast
    private var flushTask: Task<Void, Never>?
    /// Per-turn tok/s updater, run after each applied flush so the header rate
    /// keeps pace with the throttled UI (not with every raw delta).
    private var streamTick: (() -> Void)?

    private func queueContent(_ id: String, _ text: String) {
        pendingContent[id] = text; scheduleFlush()
    }
    private func queueReasoning(_ id: String, _ text: String) {
        pendingReasoning[id] = text; scheduleFlush()
    }

    private func scheduleFlush() {
        if Date().timeIntervalSince(lastFlush) >= 0.04 { flushPending(); return }
        guard flushTask == nil else { return }   // one trailing flush is enough
        flushTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 40_000_000)
            self.flushTask = nil
            self.flushPending()
        }
    }

    private func flushPending() {
        guard !pendingContent.isEmpty || !pendingReasoning.isEmpty else { return }
        lastFlush = Date()
        for (id, text) in pendingContent { setContent(id, text) }
        for (id, text) in pendingReasoning { setReasoning(id, text) }
        pendingContent = [:]; pendingReasoning = [:]
        streamTick?()
    }

    /// Apply anything still queued right now (cancels the trailing timer so a
    /// stale write can't land after e.g. the agent loop clears the bubble).
    private func flushStreamUI() {
        flushTask?.cancel(); flushTask = nil
        flushPending()
    }

    /// End-of-stream flush: the last frame always lands, then the turn's tick
    /// closure is dropped.
    private func finishStreamUI() {
        flushStreamUI()
        streamTick = nil
    }

    // MARK: - Mutation helpers

    private func index(of id: String) -> Int? { messages.firstIndex { $0.id == id } }
    private func setContent(_ id: String, _ text: String) {
        if let i = index(of: id) { messages[i].content = text }
    }
    /// Cumulative reasoning (socket sends the full thinking each tick → replace).
    private func setReasoning(_ id: String, _ text: String) {
        if let i = index(of: id) { messages[i].reasoning = text }
    }
    /// Live tokens/sec (~4 chars/token) counting reasoning + answer, updated as it
    /// streams so the header shows a running rate. `chars` is the cumulative
    /// generated length; `start` the first token's timestamp.
    private func tickRate(_ id: String, chars: Int, start: Date) {
        let dt = Date().timeIntervalSince(start)
        if dt >= 0.3, chars > 0 { genRate[id] = (Double(chars) / 4.0) / dt }
    }
    /// Append a completed tool run so the auditable card appears live. Native OWUI
    /// web-search sources arrive one-per-event (no query) — merge those into a
    /// single card; pipe cards (with a query) are appended as distinct runs.
    private func addToolUse(_ id: String, _ t: OWToolUse) {
        guard let i = index(of: id) else { return }
        if t.action == "web_search", t.query.isEmpty,
           let j = messages[i].toolUses.firstIndex(where: { $0.action == "web_search" && $0.query.isEmpty }) {
            var merged = messages[i].toolUses[j]
            if !t.results.isEmpty { merged.results += (merged.results.isEmpty ? "" : "\n\n---\n\n") + t.results }
            for s in t.sources where !merged.sources.contains(where: { $0.url == s.url }) { merged.sources.append(s) }
            messages[i].toolUses[j] = merged
        } else if !messages[i].toolUses.contains(where: { $0.id == t.id }) {
            messages[i].toolUses.append(t)
        }
    }

    // MARK: - Background completion + local notification

    /// Post a local notification if the reply finished while the app was backgrounded
    /// — so a mid-stream reply the user walked away from pings them when it's ready.
    private func notifyReplyIfBackgrounded(_ id: String) {
        #if canImport(UIKit)
        guard UIApplication.shared.applicationState == .background else { return }
        guard let i = index(of: id) else { return }
        let body = messages[i].content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let snippet = body.count > 140 ? String(body.prefix(140)) + "…" : body
        let heading = title.isEmpty ? L("Resposta pronta") : title
        LocalNotifier.replyFinished(title: heading, body: snippet, threadID: chatID)
        #endif
    }

    #if canImport(UIKit)
    private var backgroundHold: UIBackgroundTaskIdentifier = .invalid
    private func beginBackgroundHold() {
        endBackgroundHold()
        backgroundHold = UIApplication.shared.beginBackgroundTask(withName: "chat-reply") { [weak self] in
            self?.endBackgroundHold()
        }
    }
    private func endBackgroundHold() {
        guard backgroundHold != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundHold)
        backgroundHold = .invalid
    }
    #else
    private func beginBackgroundHold() {}
    private func endBackgroundHold() {}
    #endif
}
