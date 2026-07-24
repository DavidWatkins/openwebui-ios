import SwiftUI

// Shared text-input chrome: monospaced body on a themed panel with a hairline
// border. Used by the login fields and the server dialog — anywhere a bare
// TextField would be invisible (the macOS window root sets a global
// `.textFieldStyle(.plain)`, so fields carry their own chrome).

extension View {
    func styledInput(_ theme: Theme) -> some View {
        self
            .font(.ody(.body, design: .monospaced))
            .foregroundStyle(theme.fg)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(theme.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.border, lineWidth: 1))
    }
}
