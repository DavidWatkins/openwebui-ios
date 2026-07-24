import SwiftUI
import MarkdownUI
import OpenWebUIKit
#if canImport(UIKit)
import UIKit
#endif

struct MessageBubble: View {
    let message: OWMessage
    var isStreaming: Bool = false
    var client: OpenWebUIClient? = nil
    /// Branch position among siblings (1-based index, total) — nil when not a fork.
    var branch: (index: Int, total: Int)? = nil
    /// Models offered in the "retry with a different model" menu.
    var models: [OWModel] = []
    /// Live tool activity for the message being generated ("🔧 web_search: …").
    var toolStatus: String? = nil
    /// Measured generation speed (tokens/sec), shown in the header when present.
    var tokPerSec: Double? = nil
    var onEdit: ((String) -> Void)? = nil          // edited user text
    var onRegenerate: (() -> Void)? = nil
    var onRetryModel: ((String) -> Void)? = nil    // model id
    var onBranch: ((Int) -> Void)? = nil           // ±1 to switch branch
    @Environment(\.theme) private var theme
    @ObservedObject private var speech = SpeechManager.shared
    @State private var viewer: ViewerImage?
    @State private var editing = false
    @State private var draft = ""
    /// nil = follow the automatic behaviour (open while thinking, closed once the
    /// reply starts). Once the user taps, their choice wins for the rest of the view.
    @State private var reasoningOverride: Bool?
    /// User preference: keep the reasoning disclosure open once thinking is done
    /// (default is to collapse it). Set in Settings.
    @AppStorage("reasoning.expandedByDefault") private var reasoningExpandedByDefault = false
    /// Bumped on each `‹ ›` branch switch so `.sensoryFeedback` fires a tick.
    @State private var branchTap = 0

    struct ViewerImage: Identifiable { let id = UUID(); let url: String }

    private var isUser: Bool { message.role == .user }

    /// The model is thinking when reasoning is arriving but no reply text has yet.
    private var isThinking: Bool { isStreaming && message.content.isEmpty }

    /// Whether to draw the text bubble. Suppress an EMPTY bubble when the reply
    /// is only reasoning (no answer yet, not streaming) — that empty box was the
    /// "artifact" under the thinking disclosure. Still show the typing bubble while
    /// streaming, and a placeholder for a truly-empty message with nothing else.
    private var showBubble: Bool {
        if !message.content.isEmpty { return true }
        // content empty & streaming: only show the typing bubble when nothing else
        // already signals activity (reasoning disclosure or a running tool) — that
        // empty bubble between the thinking and the "Searching…" row was the artifact.
        if isStreaming { return message.reasoning == nil && toolStatus == nil }
        // content empty & settled: only a bare message (no reasoning/images/docs)
        // gets a placeholder; a reasoning-only reply shows just the disclosure.
        return message.reasoning == nil && message.imageURLs.isEmpty && message.documents.isEmpty
    }

    private func toolStatusRow(_ status: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(status).font(.ody(size: 12, design: .monospaced))
                .foregroundStyle(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity)
    }
    private var reasoningExpanded: Bool { reasoningOverride ?? (isThinking || reasoningExpandedByDefault) }

    var body: some View {
        HStack(alignment: .top) {
            if isUser { Spacer(minLength: 36) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                if !isUser { header }
                if !isUser, let reasoning = message.reasoning { reasoningView(reasoning) }
                if !isUser, !message.toolUses.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(message.toolUses) { ToolUseCard(tool: $0) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let toolStatus { toolStatusRow(toolStatus) }
                if !message.imageURLs.isEmpty { imagesView }
                if !message.documents.isEmpty { documentsView }
                if editing {
                    editor
                } else if showBubble {
                    bubble.contextMenu { messageMenu }
                }
                if !editing, !isStreaming { actionBar }
            }
            if !isUser { Spacer(minLength: 36) }
        }
        .fullScreenCover(item: $viewer) { v in ImageViewerView(url: v.url, client: client) }
    }

    /// Inline actions under a settled message: branch switcher + (assistant)
    /// copy / regenerate / retry-with-model. Kept subtle, ChatGPT/Claude-style.
    @ViewBuilder
    private var actionBar: some View {
        let canCopy = !isUser && !message.content.isEmpty
        let hasActions = branch != nil || canCopy || (!isUser && (onRegenerate != nil || onRetryModel != nil))
        if hasActions {
            HStack(spacing: 20) {
                if let b = branch { branchNav(b) }
                if canCopy { CopyButton(text: message.content, size: 12) }
                if !isUser, let onRegenerate {
                    Button { onRegenerate() } label: {
                        Image(systemName: "arrow.clockwise").actionHitTarget()
                    }
                    .buttonStyle(.plain)
                }
                if !isUser, !models.isEmpty, let onRetryModel {
                    Menu {
                        ForEach(models) { m in Button(m.shortName) { onRetryModel(m.id) } }
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath").actionHitTarget()
                    }
                }
            }
            .font(.ody(size: 12))
            .foregroundStyle(theme.secondaryText)
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
            .padding(.top, 1)
        }
    }

    private func branchNav(_ b: (index: Int, total: Int)) -> some View {
        HStack(spacing: 9) {
            Button { branchTap += 1; onBranch?(-1) } label: {
                Image(systemName: "chevron.left").actionHitTarget()
            }
            .buttonStyle(.plain).disabled(b.index <= 1)
            Text("\(b.index)/\(b.total)").font(.ody(size: 11, design: .monospaced))
            Button { branchTap += 1; onBranch?(1) } label: {
                Image(systemName: "chevron.right").actionHitTarget()
            }
            .buttonStyle(.plain).disabled(b.index >= b.total)
        }
        .sensoryFeedback(.selection, trigger: branchTap)
    }

    @ViewBuilder
    private var messageMenu: some View {
        if !message.content.isEmpty {
            Button {
                owCopyToClipboard(message.content)
            } label: { Label(L("Copiar"), systemImage: "doc.on.doc") }
        }
        if isUser, onEdit != nil {
            Button { draft = message.content; editing = true } label: {
                Label(L("Editar"), systemImage: "pencil")
            }
        }
        if !isUser, let onRegenerate {
            Button { onRegenerate() } label: { Label(L("Regenerar"), systemImage: "arrow.clockwise") }
        }
    }

    /// Editable field shown in place of a user bubble while editing.
    private var editor: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextField(L("Editar mensagem"), text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.ody(.body, design: .monospaced))
                .foregroundStyle(theme.fg)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(theme.userBubble, in: RoundedRectangle(cornerRadius: 14))
            HStack(spacing: 12) {
                Button(L("Cancelar")) { editing = false }
                    .buttonStyle(.plain).foregroundStyle(theme.secondaryText)
                Button(L("Enviar")) {
                    editing = false
                    onEdit?(draft)
                }
                .buttonStyle(.plain).foregroundStyle(theme.accent)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .font(.ody(size: 13))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var header: some View {
        HStack(spacing: 6) {
            BrandMark(size: 16)
            Text(message.model?.split(separator: "/").last.map(String.init) ?? "Open WebUI")
                .font(.ody(size: 11, design: .monospaced))
                .foregroundStyle(theme.secondaryText)
            if let tps = tokPerSec, tps > 0 {
                Text("· \(Int(tps.rounded())) tok/s")
                    .font(.ody(size: 10, design: .monospaced))
                    .foregroundStyle(theme.secondaryText.opacity(0.8))
            }
            if !message.content.isEmpty {
                Button { speech.toggle(message.content, id: message.id) } label: {
                    if speech.isPreparing(message.id) {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: speech.isSpeaking(message.id) ? "speaker.wave.2.fill" : "speaker.wave.2")
                            .font(.ody(size: 11))
                            .foregroundStyle(speech.isSpeaking(message.id) ? theme.accent : theme.secondaryText)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Collapsible extended-thinking block, shown above the reply.
    private func reasoningView(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { reasoningOverride = !reasoningExpanded }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.ody(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(reasoningExpanded ? 90 : 0))
                    if isThinking {
                        Text("Pensando…")
                    } else {
                        Text("Raciocínio")
                    }
                }
                .font(.ody(size: 11, design: .monospaced))
                .foregroundStyle(theme.secondaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if reasoningExpanded && !text.isEmpty {
                // While it streams we show only the last few lines so a long think
                // doesn't shove the reply off-screen — `.head` truncation keeps the
                // newest text visible without any scroll plumbing. Once the user
                // opens it themselves they get the whole thing.
                let windowed = isThinking && reasoningOverride == nil
                Text(text)
                    .font(.ody(size: 12, design: .monospaced))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(windowed ? 8 : nil)
                    .truncationMode(.head)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(theme.border.opacity(0.6)).frame(width: 2)
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var imagesView: some View {
        let cols = [GridItem(.adaptive(minimum: 90, maximum: 140), spacing: 6)]
        return LazyVGrid(columns: cols, alignment: isUser ? .trailing : .leading, spacing: 6) {
            ForEach(message.imageURLs, id: \.self) { url in
                Button { viewer = ViewerImage(url: url) } label: {
                    AttachmentThumb(url: url, size: 120, client: client)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border.opacity(0.4), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: 280, alignment: isUser ? .trailing : .leading)
    }

    private var documentsView: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            ForEach(message.documents) { doc in
                HStack(spacing: 6) {
                    Image(systemName: "doc.fill").font(.ody(size: 12)).foregroundStyle(theme.accent)
                    Text(doc.displayName).font(.ody(size: 11, design: .monospaced))
                        .foregroundStyle(theme.fg).lineLimit(1)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(theme.panel, in: Capsule())
                .overlay(Capsule().stroke(theme.border.opacity(0.5), lineWidth: 1))
            }
        }
    }

    @ViewBuilder
    private var bubble: some View {
        Group {
            if message.content.isEmpty && isStreaming {
                TypingDots()
            } else if isUser || isStreaming {
                // While the reply streams, render plain text — re-parsing Markdown on
                // every token makes the whole transcript churn. Settles to Markdown.
                Text(message.content)
                    .font(.ody(.body, design: .monospaced))
                    .foregroundStyle(theme.fg)
                    .textSelection(.enabled)
            } else {
                Markdown(message.content)
                    .markdownTextStyle { ForegroundColor(theme.fg) }
                    .markdownTextStyle(\.code) {
                        FontFamilyVariant(.monospaced)
                        BackgroundColor(theme.panel)
                    }
                    .markdownBlockStyle(\.codeBlock) { configuration in
                        CodeBlockView(configuration: configuration)
                    }
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(isUser ? theme.userBubble : theme.aiBubble,
                    in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.border.opacity(0.35), lineWidth: isUser ? 0 : 1))
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }
}

/// Three-dot pulsing indicator while waiting for the first token. One flipped
/// state drives all three dots; the per-dot delay staggers them into a wave.
struct TypingDots: View {
    @Environment(\.theme) private var theme
    @State private var animating = false
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(theme.fg.opacity(0.7))
                    .frame(width: 7, height: 7)
                    .scaleEffect(animating ? 1 : 0.5)
                    .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true).delay(Double(i) * 0.16),
                               value: animating)
            }
        }
        .onAppear { animating = true }
        .frame(height: 14)
    }
}

// MARK: - Action-bar helpers

extension View {
    /// Comfortable ~32pt tap target for the tiny glyph buttons in the action row.
    func actionHitTarget() -> some View {
        frame(minWidth: 32, minHeight: 32).contentShape(Rectangle())
    }
}

/// Copy-to-clipboard glyph button: light haptic + a transient checkmark (~1.2s).
struct CopyButton: View {
    let text: String
    var size: CGFloat = 12
    @Environment(\.theme) private var theme
    @State private var copied = false
    /// Bumped per tap so `.sensoryFeedback` fires even on rapid re-copies.
    @State private var copyTap = 0

    var body: some View {
        Button {
            owCopyToClipboard(text)
            copyTap += 1
            copied = true
            Task { try? await Task.sleep(nanoseconds: 1_200_000_000); copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.ody(size: size))
                .foregroundStyle(copied ? theme.accent : theme.secondaryText)
                .actionHitTarget()
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .light), trigger: copyTap)
    }
}

/// Fenced code block: panel surface, horizontal scroll for long lines, a small
/// language chip, and a copy button for the raw code.
struct CodeBlockView: View {
    let configuration: CodeBlockConfiguration
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .markdownTextStyle { FontFamilyVariant(.monospaced) }
                    .padding(12)
                    .padding(.trailing, 40)   // keep the first line clear of the controls
            }
            HStack(spacing: 2) {
                if let lang = configuration.language, !lang.isEmpty {
                    Text(lang)
                        .font(.ody(size: 10, design: .monospaced))
                        .foregroundStyle(theme.secondaryText)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(theme.bg.opacity(0.6), in: Capsule())
                }
                CopyButton(text: configuration.content, size: 11)
            }
            .padding(.horizontal, 4)
        }
        .background(theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.border.opacity(0.4), lineWidth: 1))
    }
}

/// An expandable "what the Agent searched, and what it got back" card — shown
/// under a reply for each tool run so the retrieved context is auditable.
struct ToolUseCard: View {
    let tool: OWToolUse
    @Environment(\.theme) private var theme
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: tool.icon).font(.ody(size: 11))
                    Text(tool.title).font(.ody(size: 12, design: .monospaced)).lineLimit(1)
                    Spacer(minLength: 6)
                    if !tool.sources.isEmpty {
                        Text("\(tool.sources.count)").font(.ody(size: 10, design: .monospaced))
                    }
                    Image(systemName: "chevron.right")
                        .font(.ody(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .foregroundStyle(theme.secondaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                if !tool.results.isEmpty {
                    Text(tool.results)
                        .font(.ody(size: 11, design: .monospaced))
                        .foregroundStyle(theme.secondaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !tool.sources.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(tool.sources.enumerated()), id: \.offset) { i, s in
                            if let url = URL(string: s.url) {
                                Link(destination: url) {
                                    Text("\(i + 1). \(s.title.isEmpty ? s.url : s.title)")
                                        .font(.ody(size: 11)).foregroundStyle(theme.accent).lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.panel.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.border.opacity(0.4), lineWidth: 1))
    }
}
