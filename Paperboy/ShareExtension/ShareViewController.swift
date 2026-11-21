import UIKit
import UniformTypeIdentifiers

/// "Paperboy" in the share sheet. Writes the shared page into the app group's Inbox folder as one
/// JSON file ({url, title, html, sharedAt}); the app turns it into an article and loads it onto
/// the reader the next time it runs or the reader connects. Kept free of the app's own code so it
/// starts instantly and stays within an extension's memory limit.
final class ShareViewController: UIViewController {
    static let appGroup = "group.app.paperboy.readerc67aad"
    /// A page larger than this is passed as a link only; the app fetches it itself.
    static let maxHTMLBytes = 4_000_000

    private let label = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.25)
        let card = UIView()
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 16
        card.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Sending to Paperboy…"
        label.font = .preferredFont(forTextStyle: .headline)
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(label)
        view.addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 280),
            label.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            label.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24),
            label.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { @MainActor in
            let saved = await self.saveSharedPage()
            self.label.text = saved
                ? "Sent to Paperboy.\nIt goes onto the reader at the next sync."
                : "Paperboy could not read a link from this."
            try? await Task.sleep(for: .seconds(saved ? 1.1 : 2))
            self.extensionContext?.completeRequest(returningItems: nil)
        }
    }

    private func saveSharedPage() async -> Bool {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        var page: [String: Any] = [:]

        // Safari: the result of SharePage.js.
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier) {
            if let item = try? await provider.loadItem(forTypeIdentifier: UTType.propertyList.identifier),
               let dictionary = item as? NSDictionary,
               let results = dictionary[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any] {
                page = results
            }
        }
        // Everything else: a link.
        if page["url"] == nil {
            for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                if let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                    page["url"] = url.absoluteString
                    break
                }
            }
        }
        // Some apps share the link as text.
        if page["url"] == nil {
            for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                if let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String,
                   let range = text.range(of: #"https?://\S+"#, options: .regularExpression) {
                    page["url"] = String(text[range])
                    break
                }
            }
        }
        guard let url = page["url"] as? String, url.hasPrefix("http") else { return false }

        var record: [String: Any] = ["url": url, "sharedAt": Date().timeIntervalSince1970]
        if let title = page["title"] as? String, !title.isEmpty { record["title"] = title }
        if let html = page["html"] as? String, !html.isEmpty, html.utf8.count <= Self.maxHTMLBytes { record["html"] = html }

        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup),
              let data = try? JSONSerialization.data(withJSONObject: record) else { return false }
        let inbox = container.appendingPathComponent("Inbox", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            try data.write(to: inbox.appendingPathComponent("\(UUID().uuidString).json"), options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
