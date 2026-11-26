import Foundation
import PaperboyCore
import WebKit
#if canImport(UIKit)
import UIKit
#endif

/// Reads the signed-in Following page and the same story pages the user can open in Medium.
@MainActor
final class MediumSource {
    private let limiter = RateLimiter(interval: .seconds(1))

    func fetchArticle(_ url: String, timeout: TimeInterval = 25) async throws -> Article {
        try await limiter.wait()
        try Task.checkCancellation()
        return try await MediumPage().article(url: url, timeout: timeout)
    }

    func fetchNew(settings: AppSettings, store: ArticleStore, deadline: Date) async -> FetchSummary {
        var summary = FetchSummary()
        guard await WebSession.isSignedIn(.medium) else { return summary }
        let oldest = Date().addingTimeInterval(-settings.unreadDays * 86_400)
        let links: [String]
        do {
            let html = try await MediumPage().followingHTML(timeout: max(1, min(25, deadline.timeIntervalSinceNow)))
            links = MediumDiscovery.storyLinks(in: html)
            if links.isEmpty { summary.notes.append("Medium: no stories found on the Following page; open Medium in Paperboy to check your sign-in") }
        } catch {
            summary.notes.append("Medium Following: \(error.localizedDescription)")
            return summary
        }
        var attempted = 0
        for url in links {
            if Task.isCancelled || Date() >= deadline || attempted >= settings.mediumMaxPerFetch { break }
            let id = ArticleID(canonicalURL: url)
            if await store.isKnown(id) { continue }
            attempted += 1
            do {
                var article = try await fetchArticle(url, timeout: max(1, min(25, deadline.timeIntervalSinceNow)))
                article.url = url
                guard article.date >= oldest else { continue }
                article = await ArticleImagePipeline.prepare(article)
                try await store.add(article)
                summary.added += 1
                AppLog.post("Medium stored: \(article.title)")
            } catch is CancellationError { break }
            catch {
                summary.failed += 1
                summary.notes.append("Medium: \(error.localizedDescription)")
            }
        }
        return summary
    }
}

/// Each load owns its navigation and timeout, so sharing during a fetch cannot supersede it.
@MainActor
private final class MediumPage: NSObject, WKNavigationDelegate {
    private var web: WKWebView?
    private var loaded: CheckedContinuation<Void, Error>?

    func article(url: String, timeout: TimeInterval) async throws -> Article {
        let html = try await load(url: url, timeout: timeout)
        var article = try await ReaderModeExtractor().article(html: html, url: url)
        if article.source.isEmpty || MediumDiscovery.isMediumHost(article.source) { article.source = "Medium" }
        return article
    }

    func followingHTML(timeout: TimeInterval) async throws -> String {
        _ = try await load(url: MediumDiscovery.followingURL, timeout: timeout, linksOnly: true)
        return snapshot
    }

    private var snapshot = ""

    private func load(url: String, timeout: TimeInterval, linksOnly: Bool = false) async throws -> String {
        guard let address = URL(string: url), address.scheme == "https" else { throw URLError(.badURL) }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WebSession.dataStore
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        self.web = web
        web.navigationDelegate = self
        #if canImport(UIKit)
        web.alpha = 0
        web.isUserInteractionEnabled = false
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            .first { $0.isKeyWindow }?.insertSubview(web, at: 0)
        #endif
        defer {
            web.stopLoading()
            web.navigationDelegate = nil
            #if canImport(UIKit)
            web.removeFromSuperview()
            #endif
            self.web = nil
        }
        let watchdog = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
            self?.finish(.failure(URLError(.timedOut)))
            self?.web?.stopLoading()
        }
        defer { watchdog.cancel() }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                loaded = continuation
                web.load(URLRequest(url: address))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(.failure(CancellationError()))
                self?.web?.stopLoading()
            }
        }
        try await Task.sleep(for: .milliseconds(500))
        if linksOnly {
            // Exclude sidebar recommendations and account/navigation links.
            snapshot = try await web.evaluateJavaScript("""
                (() => { const main = document.querySelector('main') || document.body;
                return Array.from(main.querySelectorAll('a[href]'))
                    .filter(a => !a.closest('aside, nav, header, footer, [role="complementary"]'))
                    .map(a => '<a href="' + a.href.replace(/&/g, '&amp;').replace(/"/g, '&quot;') + '"></a>').join(''); })()
                """) as? String ?? ""
            return snapshot
        }
        return try await web.evaluateJavaScript("document.documentElement.outerHTML") as? String ?? ""
    }

    private func finish(_ result: Result<Void, Error>) {
        let continuation = loaded
        loaded = nil
        continuation?.resume(with: result)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.failure(URLError(.cannotLoadFromNetwork))) }
}
