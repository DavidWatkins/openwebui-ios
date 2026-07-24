import UIKit
import UniformTypeIdentifiers

/// Minimal (no-UI) share handler: grab the shared URL / text / file, stash it in
/// the App Group for the main app, nudge the app open, and dismiss. If iOS blocks
/// the open, the content still waits in the inbox for the next app launch.
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        process()
    }

    private var providers: [NSItemProvider] {
        (extensionContext?.inputItems as? [NSExtensionItem])?.flatMap { $0.attachments ?? [] } ?? []
    }

    private func process() {
        // File (PDF/doc) first — richest content — then a web URL, then text.
        if let p = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] value, _ in
                if let url = value as? URL, url.isFileURL { self?.stashFile(url) }
                self?.finish()
            }
        } else if let p = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
            p.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] value, _ in
                if let url = value as? URL {
                    SharedInbox.write(SharedItem(kind: .url, text: url.absoluteString))
                }
                self?.finish()
            }
        } else if let p = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) {
            p.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { [weak self] value, _ in
                if let text = value as? String {
                    SharedInbox.write(SharedItem(kind: .text, text: text))
                }
                self?.finish()
            }
        } else {
            finish()
        }
    }

    private func stashFile(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        let ext = url.pathExtension.isEmpty ? "dat" : url.pathExtension
        let name = "share-\(UUID().uuidString).\(ext)"
        guard SharedInbox.writeFile(data, name: name) != nil else { return }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        SharedInbox.write(SharedItem(kind: .file, fileName: name,
                                     displayName: url.lastPathComponent, mime: mime))
    }

    private func finish() {
        openHostApp()
        DispatchQueue.main.async { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }

    /// Open the main app via its URL scheme so the share is handled immediately.
    /// Uses the responder chain (extensions can't call UIApplication directly);
    /// harmless if it fails — the App Group inbox is the source of truth.
    private func openHostApp() {
        guard let url = URL(string: "openwebui://share") else { return }
        let selector = NSSelectorFromString("openURL:")
        var responder: UIResponder? = self
        while let r = responder {
            if r.responds(to: selector) {
                _ = r.perform(selector, with: url)
                return
            }
            responder = r.next
        }
    }
}
