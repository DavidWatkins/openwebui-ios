import SwiftUI
import OpenWebUIKit

/// Single-surface shell once logged in: the chat list is the app. Voice launches
/// from inside a chat; image generation is a chat mode; Notes and Workspace live
/// behind the menu in the chat list's toolbar. (Formerly a 5-tab TabView.)
struct MainView: View {
    let app: AppState

    var body: some View {
        ChatListView(app: app)
    }
}

/// The chat list (Conversas tab).
struct ChatListView: View {
    let app: AppState
    @EnvironmentObject private var themes: ThemeStore
    @Environment(\.theme) private var theme
    @StateObject private var store: ChatStore
    @State private var path: [ChatRoute] = []
    @ObservedObject private var launch = AppLaunch.shared
    @State private var showSettings = false
    @State private var showNotes = false
    @State private var showWorkspace = false
    @State private var showImages = false
    @State private var search = ""
    @State private var searchTask: Task<Void, Never>?
    /// Open a fresh chat on first launch (Claude-style), once per session.
    @State private var didAutoOpen = false
    @State private var renaming: OWChatSummary?
    @State private var renameText = ""
    @State private var shareItem: ShareableURL?
    #if os(macOS)
    /// Split-view selection (macOS): the chat the detail pane shows.
    @State private var selection: ChatRoute?
    #endif

    init(app: AppState) {
        self.app = app
        _store = StateObject(wrappedValue: app.makeChatStore())
    }

    enum ChatRoute: Hashable {
        case existing(OWChatSummary)
        /// `token` keeps repeated "new chat" opens distinct (fresh detail on macOS,
        /// distinct path elements on iOS).
        case new(mode: ChatMode, token: UUID)
    }

    private var filtered: [OWChatSummary] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return store.chats }
        // Instant title matches over the loaded list, plus full-text results
        // (server + cached bodies) from `store.search`, deduped.
        let titleMatches = store.chats.filter { $0.title.localizedCaseInsensitiveContains(q) }
        let ids = Set(titleMatches.map(\.id))
        return titleMatches + store.searchResults.filter { !ids.contains($0.id) }
    }

    var body: some View {
        shell
        .tint(theme.accent)
        // New-chat / camera App Intents (Action Button, Siri, Shortcuts) route here.
        .onChange(of: launch.action) { _, _ in routeLaunch() }
        .onAppear { routeLaunch() }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(app).environmentObject(themes).macSheetFrame()
        }
        .sheet(isPresented: $showNotes) {
            NotesView(app: app).environment(\.theme, theme).macSheetFrame()
        }
        .sheet(isPresented: $showWorkspace) {
            WorkspaceView(app: app).environment(\.theme, theme).macSheetFrame()
        }
        .sheet(isPresented: $showImages) {
            ImageGenView(app: app).environment(\.theme, theme).macSheetFrame()
        }
        .sheet(item: $shareItem) { item in ShareSheet(items: [item.url]) }
        .alert("Renomear conversa", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Título", text: $renameText)
            Button("Cancelar", role: .cancel) { renaming = nil }
            Button("Salvar") {
                if let c = renaming { Task { await store.rename(c, to: renameText) } }
                renaming = nil
            }
        }
    }

    /// Navigation shell: full-window push on iOS (unchanged), sidebar + detail
    /// split view on macOS (Mail/Messages idiom — the list stays in view).
    @ViewBuilder private var shell: some View {
        #if os(macOS)
        NavigationSplitView {
            listPane
                .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        } detail: {
            if let route = selection {
                chatDetail(route)
                    .id(route)   // new route → fresh ChatScreen (its view model is per-chat)
            } else {
                emptyDetail
            }
        }
        #else
        NavigationStack(path: $path) {
            listPane
                .navigationDestination(for: ChatRoute.self) { route in chatDetail(route) }
        }
        #endif
    }

    /// The chat list + its toolbar — the split view's sidebar on macOS, the
    /// NavigationStack root on iOS.
    private var listPane: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            content
        }
        .navigationTitle("Open WebUI")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                // Secondary destinations tuck behind one menu so the chat list
                // stays the single top-level surface (no more tab bar).
                Menu {
                    Button { showSettings = true } label: { Label("Ajustes", systemImage: "gearshape") }
                    Divider()
                    Button { showNotes = true } label: { Label("Notas", systemImage: "note.text") }
                    Button { showImages = true } label: { Label("Imagem", systemImage: "photo.artframe") }
                    Button { showWorkspace = true } label: { Label("Workspace", systemImage: "square.grid.2x2") }
                } label: {
                    Image(systemName: "line.3.horizontal")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                // Opens a new chat in the user's default mode; the mode can be
                // changed inside the chat (server / on-device / temporary).
                Button { openRoute(.new(mode: app.preferredChatMode, token: UUID())) } label: {
                    Image(systemName: "square.and.pencil")
                }
            }
        }
        .task { await store.load() }
        .refreshable { await store.load() }
        .onAppear {
            // Boot straight into a new chat (Claude iOS style); the list is one
            // back-swipe away (iOS) / stays put in the sidebar (macOS). Once per
            // session so returning here doesn't re-open.
            // Skip when a launch intent is pending — `routeLaunch()` opens that chat
            // instead, and this would stack a second empty one on top of it.
            if !didAutoOpen, launch.action == nil {
                didAutoOpen = true
                openRoute(.new(mode: app.preferredChatMode, token: UUID()))
            }
        }
    }

    @ViewBuilder private func chatDetail(_ route: ChatRoute) -> some View {
        switch route {
        case .existing(let c):
            ChatScreen(app: app, chat: c, onChanged: { Task { await store.load() } })
        case .new(let mode, _):
            ChatScreen(app: app, chat: nil, mode: mode, onChanged: { Task { await store.load() } })
        }
    }

    /// Open a chat: push on iOS, select into the detail pane on macOS.
    private func openRoute(_ route: ChatRoute) {
        #if os(macOS)
        selection = route
        #else
        path.append(route)
        #endif
    }

    #if os(macOS)
    /// Detail-pane placeholder while no chat is selected.
    private var emptyDetail: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            VStack(spacing: 14) {
                BrandMark(size: 56)
                Text("Selecione uma conversa")
                    .font(.ody(.headline, design: .monospaced))
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }
    #endif

    @ViewBuilder private var content: some View {
        if store.chats.isEmpty && store.loading {
            ProgressView().tint(theme.accent)
        } else if store.chats.isEmpty {
            emptyState
        } else {
            list
        }
    }

    private var list: some View {
        List {
            ForEach(filtered) { chat in
                Button { openRoute(.existing(chat)) } label: { row(chat) }
                    .buttonStyle(.plain)
                    .listRowBackground(theme.bg)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { Task { await store.delete(chat) } } label: {
                            Label("Apagar", systemImage: "trash")
                        }
                        Button { startRename(chat) } label: {
                            Label("Renomear", systemImage: "pencil")
                        }.tint(theme.accent)
                    }
                    .swipeActions(edge: .leading) {
                        Button { Task { await store.pin(chat) } } label: {
                            Label(LocalizedStringKey(chat.pinned ? "Desafixar" : "Fixar"), systemImage: "pin")
                        }.tint(.orange)
                    }
                    .contextMenu { chatActions(chat) }
            }
            if let err = store.error {
                Text(err).font(.ody(.footnote, design: .monospaced))
                    .foregroundStyle(theme.accent).listRowBackground(theme.bg)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .searchable(text: $search, prompt: "Buscar conversas")
        .onChange(of: search) { _, q in
            // Debounce: full-text search fires ~300ms after the last keystroke.
            searchTask?.cancel()
            let query = q
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }
                await store.search(query)
            }
        }
    }

    private func row(_ chat: OWChatSummary) -> some View {
        HStack(spacing: 10) {
            if chat.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(theme.accent) }
            // On-device-only chats are badged so they're distinguishable from
            // server chats in the same list.
            if chat.isLocal { Image(systemName: "iphone").font(.caption2).foregroundStyle(theme.accent) }
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.title).font(.ody(.subheadline, design: .monospaced))
                    .foregroundStyle(theme.fg).lineLimit(1)
                // A search match excerpt, when this row came from full-text search.
                if let snippet = chat.snippet, !snippet.isEmpty {
                    Text(snippet).font(.ody(size: 10, design: .monospaced))
                        .foregroundStyle(theme.secondaryText).lineLimit(1)
                }
                if let ts = chat.updatedAt {
                    Text(RelativeDate.string(ts))
                        .font(.ody(size: 10, design: .monospaced)).foregroundStyle(theme.secondaryText)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(theme.secondaryText.opacity(0.5))
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// Native Open WebUI chat actions (long-press menu).
    @ViewBuilder private func chatActions(_ chat: OWChatSummary) -> some View {
        Button { Task { await store.pin(chat) } } label: {
            Label(LocalizedStringKey(chat.pinned ? "Desafixar" : "Fixar"), systemImage: chat.pinned ? "pin.slash" : "pin")
        }
        Button { startRename(chat) } label: { Label("Renomear", systemImage: "pencil") }
        Button { Task { await store.clone(chat) } } label: { Label("Clonar", systemImage: "doc.on.doc") }
        Button {
            Task { if let u = await store.shareLink(chat) { shareItem = ShareableURL(url: u) } }
        } label: { Label("Compartilhar", systemImage: "square.and.arrow.up") }
        Button {
            Task { await store.unshare(chat) }
        } label: { Label("Parar de compartilhar", systemImage: "link.badge.minus") }
        Button {
            Task { if let u = await store.export(chat) { shareItem = ShareableURL(url: u) } }
        } label: { Label("Baixar", systemImage: "arrow.down.doc") }
        Button { Task { await store.archive(chat) } } label: { Label("Arquivar", systemImage: "archivebox") }
        Divider()
        Button(role: .destructive) { Task { await store.delete(chat) } } label: {
            Label("Excluir", systemImage: "trash")
        }
    }

    private func startRename(_ chat: OWChatSummary) {
        renameText = chat.title
        renaming = chat
    }

    /// New-chat / camera App Intents open a fresh chat here. (Voice is handled by
    /// RootView.) The camera intent leaves `openCameraOnNewChat` set for ChatScreen.
    private func routeLaunch() {
        guard let a = launch.action, a == .newChat || a == .camera || a == .share else { return }
        openRoute(.new(mode: app.preferredChatMode, token: UUID()))
        didAutoOpen = true   // this IS the boot chat → don't let the list auto-open a 2nd
        launch.consume()     // openCameraOnNewChat / pendingShare stay for ChatScreen
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            BrandMark(size: 56)
            Text("Nenhuma conversa ainda")
                .font(.ody(.headline, design: .monospaced)).foregroundStyle(theme.fg)
            Button { openRoute(.new(mode: app.preferredChatMode, token: UUID())) } label: {
                Label("Nova conversa", systemImage: "square.and.pencil")
                    .font(.ody(.subheadline, design: .monospaced))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(theme.accent, in: Capsule()).foregroundStyle(.white)
            }
        }
    }
}

/// Identifiable wrapper so a URL can drive a `.sheet(item:)`.
struct ShareableURL: Identifiable {
    let id = UUID()
    let url: URL
}

/// Bridges the platform share UI for share links / file export.
#if os(iOS)
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
#else
/// macOS: simple share via NSSharingServicePicker anchored to a plain view.
struct ShareSheet: View {
    let items: [Any]
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 14) {
            Text("Compartilhar").font(.headline)
            if let url = items.first as? URL {
                Text(url.absoluteString).font(.caption).textSelection(.enabled)
                Button("Copiar link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    dismiss()
                }
            }
            Button("Fechar") { dismiss() }
        }
        .padding(24)
        .frame(minWidth: 420)
    }
}
#endif

/// Relative-time formatter that follows the app's selected UI language, not a
/// fixed locale — otherwise "3 sem"/"agora" leak Portuguese into every other
/// language. The locale is re-read on each call so a runtime language switch
/// (LanguageManager) takes effect without an app relaunch.
enum RelativeDate {
    private static let fmt: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
    static func string(_ epochSeconds: Double) -> String {
        fmt.locale = LanguageManager.shared.locale
        return fmt.localizedString(for: Date(timeIntervalSince1970: epochSeconds), relativeTo: Date())
    }
}
