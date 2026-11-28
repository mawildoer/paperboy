import Foundation

/// Imports a resolved share. Only the publisher callback receives recognized article links.
@MainActor
public enum SharedArticleImport {
    public typealias Fetch = (article: Article, publisher: SharedPublisher?)

    public static func run(_ page: SharedPage, store: ArticleStore, substackPublications: [String],
                           fetchPublisher: (SharedPublisher, URL) async throws -> Article,
                           fetchOther: (SharedPage) async throws -> Fetch) async throws -> StoredArticle {
        guard let url = URL(string: page.url) else { throw URLError(.badURL) }
        let canonical = EconomistDiscovery.storyURL(url)?.absoluteString ?? URLCanonicalizer.canonicalize(page.url)
        let id = ArticleID(canonicalURL: canonical)
        let existing = await store.article(id)
        let publisher: SharedPublisher? = page.pdfFile == nil
            ? SharedPublisher.identify(url, sharedHTML: page.html, substackPublications: substackPublications) ?? existing?.sharedPublisher
            : nil

        let fetched: Fetch
        if let publisher {
            fetched = (try await fetchPublisher(publisher, url), publisher)
        } else if let existing, !existing.isRetired {
            try await store.setLoad(id, existing.read || existing.load == .lock ? .lock : .load)
            return await store.article(id) ?? existing
        } else {
            fetched = try await fetchOther(page)
        }
        var article = fetched.article
        if fetched.publisher == nil {
            article.url = canonical
        } else if let existing, !existing.isRetired, article.id != id, await !store.isKnown(article.id) {
            // Older builds keyed some redirects by the shared URL. Keep the reader's existing identity.
            article.url = existing.url
        }
        article = await ArticleImagePipeline.prepare(article)
        try Task.checkCancellation()
        return try await store.addShared(article, refreshExisting: fetched.publisher != nil, publisher: fetched.publisher)
    }
}
