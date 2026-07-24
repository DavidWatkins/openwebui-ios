import SwiftUI
import OpenWebUIKit

/// Minimal settings: appearance, account, server — fully themed (rows use
/// theme.panel, headers/text use theme colors) + the Hermes-style backdrop.
struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var themes: ThemeStore
    @EnvironmentObject private var lang: LanguageManager
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var showServer = false
    // Default tool set for NEW chats (shared keys with ChatViewModel's per-chat
    // toggles, so a chat inherits these on open). Thinking defaults ON.
    @AppStorage("tool.search") private var toolSearch = false
    @AppStorage("tool.weather") private var toolWeather = false
    @AppStorage("tool.code") private var toolCode = false
    @AppStorage("tool.image") private var toolImage = false
    @AppStorage("tool.thinking") private var toolThinking = true
    /// Keep the reasoning disclosure open once thinking finishes (default: collapse).
    @AppStorage("reasoning.expandedByDefault") private var reasoningExpandedDefault = false
    /// Dump raw socket frames to the Xcode console (to capture native tool events).
    @AppStorage("socket.debug") private var socketDebug = false

    var body: some View {
        NavigationStack {
            ZStack {
                theme.bg.ignoresSafeArea()
                if theme.backdrop { ThemeBackdrop(theme: theme) }
                List {
                    section("IDIOMA") {
                        NavigationLink {
                            LanguagePickerView()
                        } label: {
                            Label {
                                HStack {
                                    Text("Idioma").font(.ody(.body, design: .monospaced)).foregroundStyle(theme.fg)
                                    Spacer(minLength: 8)
                                    Text(verbatim: lang.isAutomatic
                                         ? "🌐 \(LanguageManager.deviceLanguage().endonym)"
                                         : "\(lang.current.flag) \(lang.current.endonym)")
                                        .font(.ody(.subheadline, design: .monospaced))
                                        .foregroundStyle(theme.secondaryText).lineLimit(1)
                                }
                            } icon: { Image(systemName: "globe").foregroundStyle(theme.accent) }
                        }
                        .listRowBackground(theme.panel)
                    }

                    section("APARÊNCIA") {
                        NavigationLink {
                            ThemePickerView(inSheet: false).environmentObject(themes)
                        } label: {
                            Label { Text("Tema").font(.ody(.body, design: .monospaced)).foregroundStyle(theme.fg) }
                            icon: { Image(systemName: "paintpalette").foregroundStyle(theme.accent) }
                        }
                        .listRowBackground(theme.panel)
                    }

                    section("MODELO") {
                        NavigationLink {
                            DefaultModelPickerView().environmentObject(app)
                        } label: {
                            Label {
                                HStack {
                                    Text("Modelo padrão").font(.ody(.body, design: .monospaced)).foregroundStyle(theme.fg)
                                    Spacer(minLength: 8)
                                    Text(defaultModelLabel)
                                        .font(.ody(.subheadline, design: .monospaced))
                                        .foregroundStyle(theme.secondaryText).lineLimit(1)
                                }
                            } icon: { Image(systemName: "cpu").foregroundStyle(theme.accent) }
                        }
                        .listRowBackground(theme.panel)
                    }

                    section("NOVA CONVERSA") {
                        Picker(selection: Binding(get: { app.preferredChatMode },
                                                  set: { app.preferredChatMode = $0 })) {
                            ForEach(ChatMode.allCases, id: \.self) { m in Text(m.label).tag(m) }
                        } label: {
                            Label {
                                Text("Modo padrão").font(.ody(.body, design: .monospaced)).foregroundStyle(theme.fg)
                            } icon: {
                                Image(systemName: "bubble.left.and.bubble.right").foregroundStyle(theme.accent)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(theme.secondaryText)
                        .listRowBackground(theme.panel)
                    }

                    section("PERSONALIZAÇÃO") {
                        TextField("Instruções personalizadas",
                                  text: Binding(get: { app.customInstructions }, set: { app.customInstructions = $0 }),
                                  axis: .vertical)
                            .font(.ody(.subheadline, design: .monospaced)).lineLimit(1...5)
                            .listRowBackground(theme.panel)
                        if !app.useDeviceLocation {
                            TextField("Localização",
                                      text: Binding(get: { app.userLocation }, set: { app.userLocation = $0 }))
                                .font(.ody(.subheadline, design: .monospaced))
                                .listRowBackground(theme.panel)
                        }
                        Toggle(isOn: Binding(get: { app.useDeviceLocation }, set: { app.useDeviceLocation = $0 })) {
                            Text("Usar localização do dispositivo").font(.ody(.body, design: .monospaced)).foregroundStyle(theme.fg)
                        }
                        .tint(theme.accent).listRowBackground(theme.panel)
                        Toggle(isOn: Binding(get: { app.includeDateTime }, set: { app.includeDateTime = $0 })) {
                            Text("Incluir data e hora").font(.ody(.body, design: .monospaced)).foregroundStyle(theme.fg)
                        }
                        .tint(theme.accent).listRowBackground(theme.panel)
                        Toggle(isOn: Binding(get: { app.memoryEnabled }, set: { app.memoryEnabled = $0; if $0 { Task { await app.loadMemories() } } })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Memória").font(.ody(.body, design: .monospaced)).foregroundStyle(theme.fg)
                                Text("Lembra fatos sobre você entre conversas.")
                                    .font(.ody(.caption, design: .monospaced)).foregroundStyle(theme.secondaryText)
                            }
                        }
                        .tint(theme.accent).listRowBackground(theme.panel)
                        if app.memoryEnabled {
                            NavigationLink { MemoryListView().environmentObject(app) } label: {
                                HStack {
                                    Text("Gerenciar memórias").font(.ody(.body, design: .monospaced)).foregroundStyle(theme.fg)
                                    Spacer()
                                    Text("\(app.memories.count)").font(.ody(.body, design: .monospaced)).foregroundStyle(theme.secondaryText)
                                }
                            }
                            .listRowBackground(theme.panel)
                        }
                    }

                    if !app.tools.isEmpty {
                        section("FERRAMENTAS") {
                            ForEach(app.tools) { t in
                                Toggle(isOn: Binding(
                                    get: { !app.disabledToolIDs.contains(t.id) },
                                    set: { on in
                                        if on { app.disabledToolIDs.remove(t.id) } else { app.disabledToolIDs.insert(t.id) }
                                    })) {
                                    Text(t.name).font(.ody(.body, design: .monospaced)).foregroundStyle(theme.fg)
                                }
                                .tint(theme.accent).listRowBackground(theme.panel)
                            }
                        }
                    }

                    section("VOZ") {
                        NavigationLink {
                            VoiceSettingsView()
                        } label: {
                            Label { Text("Voz e modelos").font(.ody(.body, design: .monospaced)).foregroundStyle(theme.fg) }
                            icon: { Image(systemName: "waveform").foregroundStyle(theme.accent) }
                        }
                        .listRowBackground(theme.panel)
                    }

                    section("CONTA") {
                        if let u = app.user {
                            labeled("Usuário", u.name ?? u.email ?? "—").listRowBackground(theme.panel)
                            if let email = u.email { labeled("Email", email).listRowBackground(theme.panel) }
                        }
                        Button(role: .destructive) {
                            Task { await app.logout(); dismiss() }
                        } label: {
                            Label("Sair", systemImage: "rectangle.portrait.and.arrow.right")
                                .font(.ody(.body, design: .monospaced))
                        }
                        .listRowBackground(theme.panel)
                    }

                    section("SERVIDOR") {
                        Button { showServer = true } label: {
                            labeled("Endereço", app.serverConfig.baseURL.host ?? app.serverConfig.baseURL.absoluteString)
                        }
                        .listRowBackground(theme.panel)
                    }

                    section("FERRAMENTAS PADRÃO") {
                        toolDefault("Buscar na web", "globe", $toolSearch)
                        toolDefault("Clima", "cloud.sun.fill", $toolWeather)
                        toolDefault("Executar código", "chevron.left.forwardslash.chevron.right", $toolCode)
                        toolDefault("Ilustrar resposta", "photo", $toolImage)
                        toolDefault("Pensar", "brain", $toolThinking)
                        toolDefault("Raciocínio expandido", "text.alignleft", $reasoningExpandedDefault)
                    }

                    Section {
                        Toggle(isOn: $socketDebug) {
                            Text(verbatim: "Socket debug log")
                                .font(.ody(.body, design: .monospaced)).foregroundStyle(theme.fg)
                        }
                        .tint(theme.accent).listRowBackground(theme.panel)
                    } header: {
                        Text(verbatim: "DEVELOPER").font(.ody(size: 11, design: .monospaced))
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Ajustes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }.foregroundStyle(theme.accent)
                }
            }
            .sheet(isPresented: $showServer) { ServerSheet().environmentObject(app) }
        }
        .tint(theme.accent)
    }

    /// Trailing label for the Settings row: the preferred model's short name if
    /// one is set and still offered, otherwise the server-default fallback.
    private var defaultModelLabel: String {
        if let id = app.preferredModelID,
           let m = app.models.first(where: { $0.id == id }) {
            return m.shortName
        }
        return L("Padrão do servidor")
    }

    @ViewBuilder private func toolDefault(_ title: LocalizedStringKey, _ icon: String, _ on: Binding<Bool>) -> some View {
        Toggle(isOn: on) {
            Label(title, systemImage: icon).font(.ody(.body, design: .monospaced)).foregroundStyle(theme.fg)
        }
        .tint(theme.accent).listRowBackground(theme.panel)
    }

    @ViewBuilder private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        Section {
            content()
        } header: {
            Text(LocalizedStringKey(title)).font(.ody(size: 11, design: .monospaced)).foregroundStyle(theme.secondaryText)
        }
    }

    private func labeled(_ key: String, _ value: String) -> some View {
        HStack {
            Text(LocalizedStringKey(key)).font(.ody(.body, design: .monospaced)).foregroundStyle(theme.fg)
            Spacer(minLength: 8)
            Text(value).font(.ody(.subheadline, design: .monospaced))
                .foregroundStyle(theme.secondaryText).lineLimit(1)
        }
    }
}

/// Server picker — shown from Settings and from the login screen.
struct ServerSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    #if os(macOS)
    @FocusState private var urlFocused: Bool
    #endif

    var body: some View {
        content
            // Start empty on first run (don't pre-fill the placeholder); keep the saved one otherwise.
            .onAppear { text = ServerConfig.isConfigured ? app.serverConfig.baseURL.absoluteString : "" }
    }

    #if os(macOS)
    // Mac: a fixed-width titled dialog — a Form in a plain sheet collapses to a
    // cramped panel, and the global `.textFieldStyle(.plain)` (OpenWebUIApp)
    // leaves a bare TextField invisible, so the field carries `styledInput`.
    // Return saves, Esc cancels.
    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Servidor")
                .font(.ody(.headline, design: .monospaced))
                .foregroundStyle(theme.fg)
            VStack(alignment: .leading, spacing: 6) {
                Text("ENDEREÇO DO SERVIDOR OPEN WEBUI")
                    .font(.ody(size: 11, design: .monospaced)).foregroundStyle(theme.secondaryText)
                TextField("http://localhost:3000", text: $text)
                    .focused($urlFocused)
                    .onSubmit(saveAndDismiss)
                    .styledInput(theme)
                Text("Ex.: http://localhost:3000  ou  https://meu-servidor.com\nSe você não digitar http(s)://, assumimos https.")
                    .font(.ody(size: 10, design: .monospaced)).foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Spacer()
                Button("Cancelar") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button("Salvar", action: saveAndDismiss)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(ServerConfig.normalize(text) == nil)
            }
            .font(.ody(.body, design: .monospaced))
        }
        .padding(20)
        .frame(width: 480)
        .background(theme.bg)
        .tint(theme.accent)
        .onAppear { urlFocused = true }
    }

    private func saveAndDismiss() {
        guard let url = ServerConfig.normalize(text) else { return }
        app.updateServer(url)
        dismiss()
    }
    #else
    private var content: some View {
        NavigationStack {
            ZStack {
                theme.bg.ignoresSafeArea()
                if theme.backdrop { ThemeBackdrop(theme: theme) }
                Form {
                    Section {
                        TextField("http://localhost:3000", text: $text)
                            .font(.ody(.body, design: .monospaced))
                            .foregroundStyle(theme.fg)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .listRowBackground(theme.panel)
                    } header: {
                        Text("ENDEREÇO DO SERVIDOR OPEN WEBUI")
                            .font(.ody(size: 11, design: .monospaced)).foregroundStyle(theme.secondaryText)
                    } footer: {
                        Text("Ex.: http://localhost:3000  ou  https://meu-servidor.com\nSe você não digitar http(s)://, assumimos https.")
                            .font(.ody(size: 10, design: .monospaced)).foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Servidor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") {
                        if let url = ServerConfig.normalize(text) { app.updateServer(url) }
                        dismiss()
                    }
                    .disabled(ServerConfig.normalize(text) == nil)
                }
            }
        }
        .tint(theme.accent)
    }
    #endif
}

/// Lets the user pick the model new chats start on. "Padrão do servidor" (nil)
/// falls back to whatever the server lists first — matching the pre-preference
/// behaviour. Selection is persisted via `AppState.preferredModelID`.
/// Kept in this file (rather than its own) so it's part of the existing target
/// membership — the app already colocates `ServerSheet` here for the same reason.
struct DefaultModelPickerView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            if theme.backdrop { ThemeBackdrop(theme: theme) }
            List {
                Section {
                    modelRow(title: L("Padrão do servidor"),
                             subtitle: app.models.first?.shortName,
                             selected: app.preferredModelID == nil) {
                        app.preferredModelID = nil
                    }
                }

                Section {
                    ForEach(app.models) { m in
                        modelRow(title: m.shortName,
                                 subtitle: m.shortName == m.name ? nil : m.name,
                                 selected: app.preferredModelID == m.id) {
                            app.preferredModelID = m.id
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .overlay {
                if app.models.isEmpty {
                    Text("Nenhum modelo disponível.")
                        .font(.ody(.subheadline, design: .monospaced))
                        .foregroundStyle(theme.secondaryText)
                }
            }
        }
        .navigationTitle("Modelo padrão")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func modelRow(title: String, subtitle: String?, selected: Bool,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.ody(.body, design: .monospaced)).foregroundStyle(theme.fg)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.ody(size: 10, design: .monospaced))
                            .foregroundStyle(theme.secondaryText).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(theme.accent)
                }
            }
        }
        .listRowBackground(theme.panel)
    }
}

/// View, delete, and clear the assistant's memories about you.
struct MemoryListView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme

    var body: some View {
        List {
            if app.memories.isEmpty {
                Text("Nenhuma memória ainda. À medida que você conversa, o assistente lembra fatos duráveis sobre você aqui.")
                    .font(.ody(.footnote, design: .monospaced)).foregroundStyle(theme.secondaryText)
                    .listRowBackground(theme.panel)
            } else {
                ForEach(app.memories) { m in
                    Text(m.content).font(.ody(.body, design: .monospaced)).foregroundStyle(theme.fg)
                        .listRowBackground(theme.panel)
                        .swipeActions {
                            Button(role: .destructive) { Task { await app.deleteMemory(m) } } label: {
                                Label("Apagar", systemImage: "trash")
                            }
                        }
                }
                Button(role: .destructive) { Task { await app.clearMemories() } } label: {
                    Text("Limpar tudo").font(.ody(.body, design: .monospaced))
                }
                .listRowBackground(theme.panel)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(theme.bg)
        .navigationTitle("Memória")
        .navigationBarTitleDisplayMode(.inline)
        .task { await app.loadMemories() }
    }
}

