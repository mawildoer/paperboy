import Foundation

/// Discover articles from the publisher's rendered site using the same WebKit session as sign-in.
@MainActor
public final class WebPublicationSource {
    public enum Publication { case medium, economist }

    public enum Capture { case links, mediumStory, economistStory }
    public struct Snapshot {
        public let url: URL
        public let html: String
        public init(url: URL, html: String) { self.url = url; self.html = html }
    }
    public typealias LoadPage = @MainActor (String, TimeInterval, Capture) async throws -> Snapshot

    private let loadPage: LoadPage
    private let publication: Publication
    private let limiter = RateLimiter(interval: .seconds(1))

    public init(_ publication: Publication, loadPage: @escaping LoadPage) {
        self.publication = publication
        self.loadPage = loadPage
    }

    public static func isEconomistPublisherURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host else { return false }
        return EconomistDiscovery.isPublisherHost(host)
    }

    public static func isEconomistShare(_ url: URL?) -> Bool {
        guard let url else { return false }
        return isEconomistPublisherURL(url) || (url.scheme == "https" && url.host?.lowercased() == "econ.st"
            && url.user == nil && url.password == nil && (url.port == nil || url.port == 443))
    }

    /// Safari can share a readable snapshot even when Paperboy has a different website session.
    public func sharedArticle(url: URL, snapshot: String?, title: String?) async throws -> Article {
        if Self.isEconomistPublisherURL(url), let snapshot,
           let article = try? await economistArticle(html: snapshot, address: url, title: title) { return article }
        try Task.checkCancellation()
        // Keep the gift token for the publisher to validate.
        let address = EconomistDiscovery.loadingURL(for: url) ?? url
        return try await fetchArticle(address.absoluteString)
    }

    private func economistArticle(html: String, address: URL, title: String? = nil) async throws -> Article {
        guard let canonical = EconomistDiscovery.storyURL(address)?.absoluteString else { throw PublicationPageError.openOnWebsite }
        var article = try await ReaderModeExtractor().article(html: html, url: canonical, title: title)
        article.url = canonical
        article.source = "The Economist"
        return article
    }

    public func fetchArticle(_ url: String, timeout: TimeInterval = 25) async throws -> Article {
        try await limiter.wait()
        try Task.checkCancellation()
        let page = try await loadPage(url, timeout, publication == .economist ? .economistStory : .mediumStory)
        if publication == .economist {
            return try await economistArticle(html: page.html, address: page.url)
        }
        var article = try await ReaderModeExtractor().article(html: page.html, url: url)
        if article.source.isEmpty || MediumDiscovery.isMediumHost(article.source) { article.source = "Medium" }
        return article
    }

    public func fetchNew(store: ArticleStore, maxPerFetch: Int, oldest: Date, deadline: Date,
                         didStore: (String) -> Void = { _ in }) async -> FetchSummary {
        var summary = FetchSummary()
        guard !Task.isCancelled, deadline > Date() else { return summary }
        let isEconomist = publication == .economist
        let name = isEconomist ? "The Economist" : "Medium"
        let links: [String]
        do {
            let listing = isEconomist ? EconomistDiscovery.frontPageURL : MediumDiscovery.followingURL
            let page = try await loadPage(listing, max(1, min(25, deadline.timeIntervalSinceNow)), .links)
            if isEconomist {
                guard Self.isEconomistPublisherURL(page.url) else { throw PublicationPageError.openOnWebsite }
                links = EconomistDiscovery.storyLinks(in: page.html)
            } else {
                links = MediumDiscovery.storyLinks(in: page.html)
            }
            if links.isEmpty { summary.notes.append("\(name): no stories found. Open \(name) in Paperboy to check your website session.") }
        } catch is CancellationError { return summary }
        catch {
            summary.notes.append("\(name): \(error.localizedDescription)")
            return summary
        }
        var attempted = 0
        for url in links {
            if Task.isCancelled || Date() >= deadline || attempted >= maxPerFetch { break }
            let id = ArticleID(canonicalURL: url)
            if await store.isKnown(id) { continue }
            attempted += 1
            do {
                var article = try await fetchArticle(url, timeout: max(1, min(25, deadline.timeIntervalSinceNow)))
                if !isEconomist { article.url = url }
                guard article.date >= oldest else { continue }
                article = await ArticleImagePipeline.prepare(article)
                try Task.checkCancellation()
                try await store.add(article)
                summary.added += 1
                didStore("\(name) stored: \(article.title)")
            } catch is CancellationError { break }
            catch {
                summary.failed += 1
                let note = "\(name): \(error.localizedDescription)"
                if summary.notes.last != note { summary.notes.append(note) }
                if isEconomist, error is PublicationPageError { break }
            }
        }
        return summary
    }
}

public enum PublicationPageError: LocalizedError {
    case openOnWebsite
    public var errorDescription: String? { "Open The Economist in Paperboy to check your sign-in, or share the readable article from Safari." }
}
