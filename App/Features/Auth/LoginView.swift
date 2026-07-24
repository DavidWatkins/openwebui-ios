import SwiftUI
import OpenWebUIKit

struct LoginView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme

    @State private var email = ""
    @State private var password = ""
    @State private var showServerSheet = false
    @FocusState private var focus: Field?

    enum Field { case email, pass }

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            BackgroundDots().opacity(0.5)

            #if os(macOS)
            // Mac: the form floats as a centered card over the dotted backdrop —
            // a full-window column reads like a stretched iPhone screen.
            formColumn
                .padding(28)
                .frame(maxWidth: 380)
                .background(theme.panel, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.border, lineWidth: 1))
            #else
            VStack(spacing: 22) {
                Spacer(minLength: 40)
                formColumn
                Spacer()
            }
            .frame(maxWidth: 420)
            .padding(24)
            #endif
        }
        .sheet(isPresented: $showServerSheet) { ServerSheet().environmentObject(app) }
        .onAppear {
            if email.isEmpty { email = app.savedEmail ?? "" }
            // First run (no server saved yet) → prompt for it right away.
            if !ServerConfig.isConfigured { showServerSheet = true }
            #if os(macOS)
            // Land the cursor in the first field (next tick — the window may not
            // be key yet when onAppear fires).
            DispatchQueue.main.async { focus = .email }
            #endif
        }
    }

    private var formColumn: some View {
        VStack(spacing: 22) {
            VStack(spacing: 10) {
                BrandMark(size: 64)
                Text("Open WebUI")
                    .font(.ody(.largeTitle, design: .monospaced).weight(.semibold))
                    .foregroundStyle(theme.fg)
                // A real Button (not a tap gesture) so it's hoverable/focusable.
                Button { showServerSheet = true } label: {
                    Text(serverLabel)
                        .font(.ody(.footnote, design: .monospaced))
                        .foregroundStyle(ServerConfig.isConfigured ? theme.secondaryText : theme.accent)
                }
                .buttonStyle(.plain)
            }

            VStack(spacing: 14) {
                field(title: "Email", text: $email, field: .email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .onSubmit { focus = .pass }

                secureField(title: "Senha", text: $password, field: .pass)
                    .submitLabel(.go)
                    .onSubmit(submit)
            }
            .padding(.horizontal, 4)

            if let err = app.loginError {
                Text(err)
                    .font(.ody(.footnote, design: .monospaced))
                    .foregroundStyle(theme.accent)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: submit) {
                HStack {
                    if app.loggingIn { ProgressView().tint(.white) }
                    Text("Entrar").font(.ody(.headline, design: .monospaced))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(theme.accent, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
            }
            #if os(macOS)
            .keyboardShortcut(.defaultAction)
            #endif
            .disabled(app.loggingIn || email.isEmpty || password.isEmpty || !ServerConfig.isConfigured)
            .opacity(app.loggingIn || email.isEmpty || password.isEmpty || !ServerConfig.isConfigured ? 0.6 : 1)
        }
    }

    private var serverLabel: String {
        guard ServerConfig.isConfigured else { return L("Toque para definir seu servidor  ›") }
        let url = app.serverConfig.baseURL
        let label = url.host.map { host in url.port.map { "\(host):\($0)" } ?? host } ?? url.absoluteString
        return label + "  ›"
    }

    private func submit() {
        focus = nil
        Task { await app.login(email: email.trimmingCharacters(in: .whitespaces), password: password) }
    }

    @ViewBuilder
    private func field(title: String, text: Binding<String>, field: Field) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(title)).font(.ody(.caption, design: .monospaced)).foregroundStyle(theme.secondaryText)
            TextField("", text: text)
                .focused($focus, equals: field)
                .styledInput(theme)
        }
    }

    @ViewBuilder
    private func secureField(title: String, text: Binding<String>, field: Field) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(title)).font(.ody(.caption, design: .monospaced)).foregroundStyle(theme.secondaryText)
            SecureField("", text: text)
                .textContentType(.password)
                .focused($focus, equals: field)
                .styledInput(theme)
        }
    }
}

// (styledInput moved to App/Config/InputStyle.swift — ServerSheet shares it.)

/// Subtle dotted background matching the web login's "dots" pattern.
struct BackgroundDots: View {
    @Environment(\.theme) private var theme
    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 20
            Canvas { ctx, size in
                let dot = Path(ellipseIn: CGRect(x: 0, y: 0, width: 1.6, height: 1.6))
                var y: CGFloat = 0
                while y < size.height {
                    var x: CGFloat = 0
                    while x < size.width {
                        var c = ctx
                        c.translateBy(x: x, y: y)
                        c.fill(dot, with: .color(theme.fg.opacity(0.08)))
                        x += spacing
                    }
                    y += spacing
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
