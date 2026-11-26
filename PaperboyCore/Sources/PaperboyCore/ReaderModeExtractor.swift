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
        let library = try String(contentsOf: Bundle.module.url(forResource: "Readability", withExtension: "js")!, encoding: .utf8)
        let wrapper = try String(contentsOf: Bundle.module.url(forResource: "ReaderMode", withExtension: "js")!, encoding: .utf8)
        _ = try await web.evaluateJavaScript(library + "\n" + wrapper)
        let value = try await web.callAsyncJavaScript(
            "return paperboyReaderHTML(html, url);", arguments: ["html": html, "url": url], in: nil, contentWorld: .page)
        if let result = value as? [String: Any], result["error"] as? String == "medium-access-required" {
            throw MediumError.accessRequired
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
