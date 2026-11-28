import Foundation
import WebKit

/// Mozilla Readability runs against an inert, detached DOM; publisher JavaScript is never run.
@MainActor
public final class ReaderModeExtractor: NSObject, WKNavigationDelegate {
    private let web: WKWebView
    private var loaded: CheckedContinuation<Void, Error>?
    private var extracting = false

    public override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        web = WKWebView(frame: .zero, configuration: config)
        super.init()
        web.navigationDelegate = self
    }

    /// Capture the visible article in an already loaded Economist page, using its current session.
    /// The returned HTML includes its origin and can be passed to article(html:url:title:).
    public static func economistSnapshot(in webView: WKWebView) async throws -> String {
        let value = try await webView.callAsyncJavaScript(
            readerScript() + "\nreturn paperboyEconomistSnapshot(document);",
            arguments: [:], in: nil, contentWorld: .defaultClient)
        guard let result = value as? [String: Any], let html = result["html"] as? String else {
            throw EconomistAccessError.accessRequired
        }
        return html
    }

    public static func sharedNYTSnapshot(in webView: WKWebView) async throws -> String {
        try await sharedSnapshot(in: webView, publisher: "nyt", accessError: SignedInStoryError.nyt)
    }

    public static func sharedMediumSnapshot(in webView: WKWebView) async throws -> String {
        try await sharedSnapshot(in: webView, publisher: "medium", accessError: MediumError.accessRequired)
    }

    private static func sharedSnapshot(in webView: WKWebView, publisher: String, accessError: any Error) async throws -> String {
        let script = try String(contentsOf: Bundle.module.url(forResource: "ReaderMode", withExtension: "js")!, encoding: .utf8)
        let value = try await webView.callAsyncJavaScript(
            script + "\nreturn paperboySharedStorySnapshot(document, publisher);",
            arguments: ["publisher": publisher], in: nil, contentWorld: .defaultClient)
        guard let html = value as? String else { throw accessError }
        return html
    }

    private static func readerScript() throws -> String {
        let library = try String(contentsOf: Bundle.module.url(forResource: "Readability", withExtension: "js")!, encoding: .utf8)
        let wrapper = try String(contentsOf: Bundle.module.url(forResource: "ReaderMode", withExtension: "js")!, encoding: .utf8)
        return library + "\n" + wrapper
    }

    public func article(html: String, url: String, title: String? = nil) async throws -> Article {
        guard !extracting else { throw URLError(.resourceUnavailable) }
        extracting = true
        defer { extracting = false }
        guard html.utf8.count <= 4_000_000 else { throw URLError(.dataLengthExceedsMaximum) }
        let rules: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "PaperboyLocalExtraction",
                encodedContentRuleList: #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#
            ) { list, error in
                if let list {
                    continuation.resume(returning: list)
                } else {
                    continuation.resume(throwing: error ?? URLError(.cannotLoadFromNetwork))
                }
            }
        }
        web.configuration.userContentController.add(rules)
        let timeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            self?.loaded?.resume(throwing: URLError(.timedOut))
            self?.loaded = nil
            self?.web.stopLoading()
        }
        defer { timeout.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loaded = continuation
            web.loadHTMLString("<html><body></body></html>", baseURL: nil)
        }
        let value = try await web.callAsyncJavaScript(
            Self.readerScript() + "\nreturn paperboyReaderHTML(html, url);",
            arguments: ["html": html, "url": url], in: nil, contentWorld: .defaultClient)
        if let result = value as? [String: Any] {
            switch result["error"] as? String {
            case "economist-access-required": throw EconomistAccessError.accessRequired
            case "medium-access-required": throw MediumError.accessRequired
            default: break
            }
        }
        guard let result = value as? [String: Any], let body = result["html"] as? String else {
            throw PageExtractorError.noArticleText(words: 0)
        }
        var article = try PageExtractor.article(pageHTML: body, url: url, sharedTitle: title, useStructuredNYT: false)
        if let text = result["title"] as? String, !text.isEmpty { article.title = text }
        if let text = result["author"] as? String, !text.isEmpty { article.author = text }
        if let text = result["source"] as? String, !text.isEmpty { article.source = text }
        if let text = result["date"] as? String, let date = ISODate.parse(text) { article.date = date }
        return article
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loaded?.resume(throwing: URLError(.cannotLoadFromNetwork))
        loaded = nil
    }
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume()
        loaded = nil
    }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing: error)
        loaded = nil
    }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing: error)
        loaded = nil
    }
}

public enum SignedInStoryError: LocalizedError {
    case nyt
    public var errorDescription: String? {
        "Paperboy couldn’t read this article in its New York Times session. Open The New York Times in Sources to check your access."
    }
}
