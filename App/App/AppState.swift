import SwiftUI
import CoreLocation
import OpenWebUIKit
import UserNotifications
import AppIntents

@MainActor
final class AppState: ObservableObject {
    enum Phase { case launching, login, main }

    @Published var phase: Phase = .launching
    @Published var serverConfig: ServerConfig
    @Published var user: OWUser?
    @Published var models: [OWModel] = []

    // Login flow
    @Published var loginError: String?
    @Published var loggingIn = false

    /// User's preferred model id for new chats. Persisted locally; nil = fall
    /// back to whatever the server lists first. Publishing it lets the Settings
    /// picker and any open composer react to a change.
    @Published var preferredModelID: String? {
        didSet {
            if let id = preferredModelID {
                UserDefaults.standard.set(id, forKey: Self.preferredModelKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.preferredModelKey)
            }
        }
    }
    private static let preferredModelKey = "chat.defaultModel"

    /// Default persistence mode for new chats (server / on-device / temporary).
    @Published var preferredChatMode: ChatMode {
        didSet { UserDefaults.standard.set(preferredChatMode.rawValue, forKey: Self.preferredModeKey) }
    }
    private static let preferredModeKey = "chat.defaultMode"

    // MARK: - Agent context & tool defaults
    //
    // These make the assistant behave more like Claude/ChatGPT: tools are
    // available by default (the model decides when to call them), and ambient
    // context (date/time, location, custom instructions) is injected each turn.

    /// Tools the user has turned OFF. Everything else is on by default, so newly
    /// added server tools are available without extra setup (opt-out model).
    @Published var disabledToolIDs: Set<String> {
        didSet { UserDefaults.standard.set(Array(disabledToolIDs), forKey: "tools.disabled") }
    }
    /// Persistent "custom instructions" prepended to every chat.
    @Published var customInstructions: String {
        didSet { UserDefaults.standard.set(customInstructions, forKey: "ctx.instructions") }
    }
    /// User-provided location (manual for now; GPS is a possible follow-up).
    @Published var userLocation: String {
        didSet { UserDefaults.standard.set(userLocation, forKey: "ctx.location") }
    }
    /// Inject the current local date & time (models often don't know "today").
    @Published var includeDateTime: Bool {
        didSet { UserDefaults.standard.set(includeDateTime, forKey: "ctx.datetime") }
    }
    /// Use the device's (coarse) GPS location as context instead of the manual
    /// field. Prompts for permission on first enable.
    @Published var useDeviceLocation: Bool {
        didSet {
            UserDefaults.standard.set(useDeviceLocation, forKey: "ctx.useGPS")
            locationProvider.setEnabled(useDeviceLocation)
        }
    }
    let locationProvider = LocationProvider()

    /// Tools available by default for a new chat (all minus the disabled ones).
    func enabledToolIDs() -> Set<String> {
        Set(tools.map(\.id)).subtracting(disabledToolIDs)
    }

    /// Ambient-context system message injected at the top of each turn, or nil
    /// if nothing is enabled. Assembled fresh so date/time is current.
    func contextSystemMessage() -> OWChatMessageInput? {
        var parts: [String] = []
        if includeDateTime {
            let f = DateFormatter(); f.dateStyle = .full; f.timeStyle = .short
            parts.append("Current date and time: \(f.string(from: Date())).")
        }
        // GPS place (if enabled and resolved) takes precedence over the manual field.
        let loc = (useDeviceLocation && !locationProvider.place.isEmpty)
            ? locationProvider.place
            : userLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        if !loc.isEmpty { parts.append("The user's location: \(loc).") }
        let inst = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !inst.isEmpty { parts.append("User instructions: \(inst)") }
        guard !parts.isEmpty else { return nil }
        return OWChatMessageInput(role: "system", text: parts.joined(separator: "\n"))
    }

    let client: OpenWebUIClient
    let completions: ChatCompletionsClient
    /// On-device chat storage (SwiftData) for `.local` chats.
    let localStore = LocalChatStore()
    private let keychain = OWKeychainStore()

    init() {
        let cfg = ServerConfig.load()
        self.serverConfig = cfg
        let c = OpenWebUIClient(config: cfg.owConfig, tokens: keychain)
        self.client = c
        self.completions = ChatCompletionsClient(client: c)
        self.preferredModelID = UserDefaults.standard.string(forKey: Self.preferredModelKey)
        self.preferredChatMode = ChatMode(rawValue: UserDefaults.standard.string(forKey: Self.preferredModeKey) ?? "") ?? .server
        let d = UserDefaults.standard
        self.disabledToolIDs = Set(d.stringArray(forKey: "tools.disabled") ?? [])
        self.customInstructions = d.string(forKey: "ctx.instructions") ?? ""
        self.userLocation = d.string(forKey: "ctx.location") ?? ""
        self.includeDateTime = (d.object(forKey: "ctx.datetime") as? Bool) ?? true
        self.useDeviceLocation = d.bool(forKey: "ctx.useGPS")
        locationProvider.setEnabled(useDeviceLocation)
    }

    /// Pre-fill the login field with the last email used.
    var savedEmail: String? { keychain.loadEmail() }

    /// On launch: if a persisted token is still valid, go straight to the app.
    func bootstrap() async {
        guard client.isAuthenticated else { phase = .login; return }
        do {
            user = try await client.me()
            await loadModels()
            phase = .main
            LocalNotifier.requestAuthorization()
        } catch {
            phase = .login
        }
    }

    func login(email: String, password: String) async {
        loginError = nil; loggingIn = true
        defer { loggingIn = false }
        do {
            user = try await client.signIn(email: email, password: password)
            keychain.saveCredentials(email: email, password: nil)   // remember email only
            await loadModels()
            phase = .main
            LocalNotifier.requestAuthorization()
        } catch {
            loginError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func logout() async {
        await client.closeSocket()
        await client.signOut()
        user = nil
        models = []
        tools = []
        phase = .login
    }

    /// Server tools/functions (incl. MCP servers exposed as tools) the model can
    /// be asked to call. Offered per-chat in the composer's tool picker.
    @Published var tools: [OWNamedItem] = []

    func loadModels() async {
        async let models = client.models()
        async let tools = client.tools()
        self.models = (try? await models) ?? []
        self.tools = (try? await tools) ?? []
    }

    /// Model id used as the default for new chats. Priority: the user's explicit
    /// preferred model → the server-side "Agent (tools)" pipe (contextual web
    /// search, weather, …) when present → the first available model.
    var defaultModel: String? {
        if let id = preferredModelID, models.contains(where: { $0.id == id }) { return id }
        if let agent = models.first(where: { $0.id.hasSuffix(".agent") || $0.name == "Agent (tools)" }) {
            return agent.id
        }
        return models.first?.id
    }

    func updateServer(_ url: URL) {
        var cfg = serverConfig
        cfg.baseURL = url
        cfg.save()
        serverConfig = cfg
        client.updateConfig(cfg.owConfig)
    }

    // Factories
    func makeChatStore() -> ChatStore { ChatStore(client: client, localStore: localStore) }
    func makeChatViewModel(chat: OWChatSummary?, mode: ChatMode? = nil) -> ChatViewModel {
        // Existing chat: mode is fixed by where it lives (local vs server). New
        // chat: use the explicitly requested mode, else the user's default.
        let resolved: ChatMode = mode ?? (chat.map { $0.isLocal ? .local : .server } ?? preferredChatMode)
        let vm = ChatViewModel(client: client, completions: completions, chat: chat,
                               models: models, defaultModel: defaultModel,
                               mode: resolved, localStore: localStore,
                               initialToolIDs: enabledToolIDs())
        // Evaluated at send time so date/time stays current and edits take effect.
        vm.contextProvider = { [weak self] in self?.contextSystemMessage() }
        return vm
    }
}

/// Coarse device location for ambient context — resolves to a "City, Region"
/// string (never raw coordinates). Reduced accuracy (city-level) for privacy;
/// only active while the user has the setting on. Colocated here to avoid a new
/// project file (see the note on `LocalChatStore`).
@MainActor
final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    /// e.g. "San Francisco, California" — empty until resolved (or if disabled).
    @Published private(set) var place: String = ""

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var enabled = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced   // city-level, not GPS-precise
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        guard on else { place = ""; return }
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
        default: break   // denied/restricted — leave place empty
        }
    }

    /// Re-request once when leaving the app for a fresh fix (cheap, opt-in).
    func refresh() {
        guard enabled,
              manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways
        else { return }
        manager.requestLocation()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        let status = m.authorizationStatus
        Task { @MainActor in
            guard enabled else { return }
            if status == .authorizedWhenInUse || status == .authorizedAlways { m.requestLocation() }
            else if status == .denied || status == .restricted { place = "" }
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let loc = locs.last else { return }
        Task { @MainActor in
            guard let marks = try? await geocoder.reverseGeocodeLocation(loc), let p = marks.first else { return }
            let city = p.locality ?? p.subAdministrativeArea ?? ""
            let region = p.administrativeArea ?? p.country ?? ""
            place = [city, region].filter { !$0.isEmpty }.joined(separator: ", ")
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}
}

// MARK: - App Intents (Action Button / Siri / Shortcuts)

enum LaunchAction: Equatable { case voice, newChat, camera, share }

/// Shared launch signal between an App Intent / the Share Extension and the UI.
/// The root view / main list observe `action` and route once signed in; a request
/// that arrives during cold launch is honored as soon as the main screen appears.
@MainActor
final class AppLaunch: ObservableObject {
    static let shared = AppLaunch()
    @Published var action: LaunchAction?
    /// Set alongside `.camera` so the freshly-opened chat pops the camera on appear.
    @Published var openCameraOnNewChat = false
    /// Content shared in from another app (Share Extension) — applied to a new chat.
    @Published var pendingShare: SharedItem?

    func request(_ a: LaunchAction) {
        action = a
        if a == .camera { openCameraOnNewChat = true }
    }
    func requestShare(_ item: SharedItem) { pendingShare = item; action = .share }
    func consume() { action = nil }
}

/// Opens the app straight into a hands-free voice conversation.
struct StartVoiceConversationIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Voice Conversation"
    static var description = IntentDescription("Open OpenWebUI and start a hands-free voice conversation.")
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        AppLaunch.shared.request(.voice); return .result()
    }
}

/// Opens the app to a fresh chat, ready to type.
struct StartNewChatIntent: AppIntent {
    static var title: LocalizedStringResource = "New Chat"
    static var description = IntentDescription("Open OpenWebUI to a new chat.")
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        AppLaunch.shared.request(.newChat); return .result()
    }
}

/// Opens the app to a new chat and pops the camera — snap a photo and ask about it.
struct AskAboutPhotoIntent: AppIntent {
    static var title: LocalizedStringResource = "Take a Photo to Ask"
    static var description = IntentDescription("Open OpenWebUI, take a photo, and ask about it in a new chat.")
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        AppLaunch.shared.request(.camera); return .result()
    }
}

struct OpenWebUIShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartVoiceConversationIntent(),
                    phrases: ["Start a voice conversation in \(.applicationName)",
                              "Talk to \(.applicationName)", "Open voice in \(.applicationName)"],
                    shortTitle: "Voice", systemImageName: "waveform")
        AppShortcut(intent: StartNewChatIntent(),
                    phrases: ["New chat in \(.applicationName)",
                              "Start a new chat in \(.applicationName)"],
                    shortTitle: "New Chat", systemImageName: "square.and.pencil")
        AppShortcut(intent: AskAboutPhotoIntent(),
                    phrases: ["Take a photo to ask \(.applicationName)",
                              "Ask \(.applicationName) about a photo"],
                    shortTitle: "Photo", systemImageName: "camera")
    }
}

/// Local (on-device) notifications — used to ping when a chat reply finishes while
/// the app is backgrounded. No push server or APNs: `UNUserNotificationCenter`
/// posts these itself. Colocated here to avoid a new project file.
enum LocalNotifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Fire a notification for a finished reply. `threadID` (the chat id) collapses
    /// repeat pings for the same chat into one thread.
    static func replyFinished(title: String, body: String, threadID: String?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let threadID { content.threadIdentifier = threadID }
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
