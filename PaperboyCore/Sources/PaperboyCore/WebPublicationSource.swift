import Foundation

/// Discover articles from the publisher's rendered site using the same WebKit session as sign-in.
@MainActor
public final class WebPublicationSource {
    public enum Publication { case medium, economist }

    public enum Capture { case links, mediumStory, economistStory, sharedMediumStory, nytStory, substackStory }
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

    /// Share imports always navigate in Paperboy's session, including when Safari has a snapshot.
    public func sharedArticle(url: URL, snapshot _: String? = nil, title _: String? = nil) async throws -> Article {
        let address = publication == .economist ? EconomistDiscovery.loadingURL(for: url) ?? url : url
        try await limiter.wait()
        try Task.checkCancellation()
        let page = try await loadPage(address.absoluteString, 25, publication == .economist ? .economistStory : .sharedMediumStory)
        if publication == .economist {
            return try await economistArticle(html: page.html, address: page.url)
        }
        let host = page.url.host?.lowercased()
        guard page.url.scheme == "https", page.url.user == nil, page.url.password == nil,
              let host, host == address.host?.lowercased() || MediumDiscovery.isMediumHost(host) ||
                SharedPublisher.identify(page.url, sharedHTML: page.html, substackPublications: []) == .medium else {
            throw MediumError.accessRequired
        }
        return try await mediumArticle(html: page.html, address: page.url.absoluteString)
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
        return try await mediumArticle(html: page.html, address: url)
    }

    private func mediumArticle(html: String, address: String) async throws -> Article {
        var article = try await ReaderModeExtractor().article(html: html, url: address)
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
                try await store.add(article, publisher: isEconomist ? .economist : .medium)
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
    public var errorDescription: String? { "Open The Economist in Paperboy to check your sign-in, then share the article again." }
}
