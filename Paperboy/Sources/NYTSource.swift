import Foundation
import PaperboyCore
import WebKit

#if canImport(UIKit)
import UIKit
#endif

/// Fetches NYT articles by loading each page in a hidden web view (NYT blocks plain HTTP
/// clients) and reading `window.__preloadedData` out of it.
///
/// UNVERIFIED, all of it, until run on the phone:
/// - that a web view which is not on screen loads and runs the page's scripts normally;
/// - that DataDome lets a signed-in WKWebView through at this pace;
/// - that any of this works while the app is in the background.
/// When the bot check appears, fetching stops for this run and the UI says so; signing in
/// again through the NYT sheet (same cookie store) is how the user clears it.
@MainActor
final class NYTSource: NSObject, WKNavigationDelegate {
    enum FetchError: Error, CustomStringConvertible {
        case timeout
        case navigation(String)
        case badURL

        var description: String {
            switch self {
            case .timeout: return "the page took too long to load"
            case .navigation(let detail): return "page load failed: \(detail)"
            case .badURL: return "not a valid URL"
            }
        }
    }

    private var webView: WKWebView?
    private var navigationContinuation: CheckedContinuation<Void, Error>?
    private let feedSession: URLSession
    /// Set when the bot check was seen; cleared by `resetBotCheck()` (after a sign-in).
    private(set) var blockedByBotCheck = false
    /// Pages that turned out not to be readable articles. Not retried until relaunch.
    private var unreadable: Set<ArticleID> = []

    override init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        feedSession = URLSession(configuration: configuration)
        super.init()
    }

    func resetBotCheck() {
        blockedByBotCheck = false
    }

    private func makeWebViewIfNeeded() -> WKWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WebSession.dataStore  // the signed-in session
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        view.navigationDelegate = self
        #if canImport(UIKit)
        // UNVERIFIED: a web view outside any window may be throttled; park it, invisible, in the
        // key window when there is one.
        view.alpha = 0
        view.isUserInteractionEnabled = false
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        window?.insertSubview(view, at: 0)
        #endif
        webView = view
        return view
    }

    /// Release the web view (and its memory) between runs.
    func tearDown() {
        #if canImport(UIKit)
        webView?.removeFromSuperview()
        #endif
        webView?.navigationDelegate = nil
        webView = nil
    }

    // MARK: Loading

    private func finishNavigation(_ result: Result<Void, Error>) {
        guard let continuation = navigationContinuation else { return }
        navigationContinuation = nil
        continuation.resume(with: result)
    }

    private func load(_ url: URL, timeout: Duration = .seconds(30)) async throws {
        let webView = makeWebViewIfNeeded()
        finishNavigation(.failure(FetchError.navigation("superseded")))
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { self?.finishNavigation(.failure(FetchError.timeout)) }
        }
        defer { watchdog.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            navigationContinuation = continuation
            webView.load(URLRequest(url: url))
        }
    }

    private func evaluate(_ script: String) async throws -> String {
        let webView = makeWebViewIfNeeded()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    continuation.resume(throwing: FetchError.navigation(error.localizedDescription))
                } else {
                    continuation.resume(returning: (result as? String) ?? "")
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishNavigation(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishNavigation(.failure(FetchError.navigation(error.localizedDescription)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishNavigation(.failure(FetchError.navigation(error.localizedDescription)))
    }

    // MARK: Fetching

    /// Load one article page and parse it.
    func fetchArticle(_ urlString: String) async throws -> Article {
        guard let url = URL(string: urlString) else { throw FetchError.badURL }
        try await load(url)
        // The data is in the initial HTML, but give the page a moment anyway.
        try await Task.sleep(for: .milliseconds(400))
        let html = try await evaluate("document.documentElement.outerHTML")
        if NYTParser.looksLikeCaptcha(html) { throw NYTError.captcha }
        if let article = try? await ReaderModeExtractor().article(html: html, url: urlString) { return article }
        let text = try await evaluate(NYTParser.extractionJavaScript)
        if text.isEmpty { throw NYTError.noPreloadedData }
        return try NYTParser.parse(preloadedData: text).article(fallbackURL: urlString)
    }

    /// Article URLs from the configured feeds and section pages, newest first.
    func discover(feeds: [String]) async -> (items: [FeedItem], notes: [String]) {
        var items: [FeedItem] = []
        var notes: [String] = []
        for feed in feeds {
            if Task.isCancelled { break }
            let trimmed = feed.trimmingCharacters(in: .whitespaces)
            guard let url = URL(string: trimmed), let host = url.host?.lowercased() else { continue }
            do {
                if host.hasPrefix("rss.") || url.pathExtension.lowercased() == "xml" {
                    // RSS is public and not behind the bot check: plain URLSession, no cookies.
                    let (data, _) = try await feedSession.data(from: url)
                    items += NYTDiscovery.parseFeed(data)
                } else {
                    // A section page: load it like a reader would and collect its article links.
                    try await load(url)
                    let html = try await evaluate("document.documentElement.outerHTML")
                    if NYTParser.looksLikeCaptcha(html) {
                        blockedByBotCheck = true
                        notes.append("NYT showed its bot check on \(trimmed)")
                        break
                    }
                    items += NYTDiscovery.articleLinks(inSectionHTML: html).map { FeedItem(url: $0, title: "", date: nil) }
                }
            } catch {
                notes.append("NYT \(trimmed): \(error)")
            }
        }
        var seen = Set<String>()
        let unique = items.filter { NYTDiscovery.isArticleURL($0.url) && seen.insert($0.url).inserted }
        // Dated items newest first; undated ones (section pages) keep their page order after them.
        let dated = unique.filter { $0.date != nil }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        return (dated + unique.filter { $0.date == nil }, notes)
    }

    /// Discover and fetch new articles, at a human pace, within the daily cap.
    func fetchNew(settings: AppSettings, store: ArticleStore, deadline: Date) async -> FetchSummary {
        var summary = FetchSummary()
        guard !blockedByBotCheck else {
            summary.notes.append("NYT is waiting for you to pass its bot check: sign in to NYT again")
            return summary
        }
        defer { tearDown() }

        // The cap counts articles fetched in the last 24 hours.
        let dayAgo = Date().addingTimeInterval(-86_400)
        let fetchedToday = await store.all().filter { $0.source == "The New York Times" && $0.fetchedAt > dayAgo }.count
        var budget = max(0, settings.nytDailyCap - fetchedToday)
        guard budget > 0 else { return summary }

        let discovery = await discover(feeds: settings.nytFeeds)
        summary.notes += discovery.notes

        var first = true
        for item in discovery.items {
            if budget <= 0 || blockedByBotCheck || Task.isCancelled || Date() >= deadline { break }
            let id = ArticleID(canonicalURL: URLCanonicalizer.canonicalize(item.url))
            if unreadable.contains(id) { continue }
            if await store.isKnown(id) { continue }
            // Human-scale pacing: a few seconds between pages, not a fixed beat.
            if !first {
                do { try await Task.sleep(for: .seconds(Double.random(in: 4...9))) } catch { break }
            }
            first = false
            do {
                var article = try await fetchArticle(item.url)
                // Keep the id tied to the URL discovery used, so "already known" stays true.
                article.url = URLCanonicalizer.canonicalize(item.url)
                article = await ArticleImagePipeline.prepare(article)
                try await store.add(article, publisher: .nyt)
                summary.added += 1
                budget -= 1
                AppLog.post("NYT stored: \(article.title)")
            } catch NYTError.captcha {
                blockedByBotCheck = true
                summary.failed += 1
                summary.notes.append("NYT showed its bot check; stopping until you sign in again")
            } catch let error as NYTError {
                // Not an article we can read (live blog, interactive…): do not try again this launch.
                unreadable.insert(id)
                summary.failed += 1
                summary.notes.append("\(item.title.isEmpty ? item.url : item.title): \(error)")
            } catch {
                summary.failed += 1
                summary.notes.append("\(item.title.isEmpty ? item.url : item.title): \(error)")
            }
        }
        return summary
    }
}
