import Foundation
import PaperboyCore

/// Fetches posts from Substack's own JSON endpoints using the session cookies copied from the
/// login web view. At most one request per second; a 429 is honoured via Retry-After.
actor SubstackSource {
    private let session: URLSession
    private let limiter = RateLimiter(interval: .seconds(1))
    /// Posts that could not be read (no access, not a text post). Not retried until relaunch.
    private var unreadable: Set<ArticleID> = []

    init() {
        let configuration = URLSessionConfiguration.default
        // The cookies copied from the web view live in the shared cookie storage.
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .onlyFromMainDocumentDomain
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    enum FetchError: Error, CustomStringConvertible {
        case http(Int)
        case rateLimited
        case notHTTP
        case previewOnly

        var description: String {
            switch self {
            case .http(let status): return "HTTP \(status)"
            case .rateLimited: return "rate limited (429)"
            case .notHTTP: return "not an HTTP response"
            case .previewOnly: return "only the free preview is available to this sign-in"
            }
        }
    }

    /// One paced GET. On 429 it waits as told (bounded) and tries once more.
    private func get(_ url: URL) async throws -> Data {
        for attempt in 0..<2 {
            try await limiter.wait()
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw FetchError.notHTTP }
            if http.statusCode == 429 {
                let delay = RetryAfter.delay(from: http.value(forHTTPHeaderField: "Retry-After"), fallback: 30, cap: 120)
                AppLog.post("Substack: 429 from \(url.host ?? "?"), waiting \(Int(delay)) s")
                await limiter.backOff(.seconds(delay))
                if attempt == 0 { continue }
                throw FetchError.rateLimited
            }
            guard (200..<300).contains(http.statusCode) else { throw FetchError.http(http.statusCode) }
            return data
        }
        throw FetchError.rateLimited
    }

    /// Rough word count of an HTML body, to tell a full post from a paywall teaser.
    private static func wordCount(html: String) -> Int {
        var words = 0
        var inTag = false
        var inWord = false
        for character in html.unicodeScalars {
            if character == "<" { inTag = true; inWord = false; continue }
            if character == ">" { inTag = false; continue }
            if inTag { continue }
            let isSpace = character.properties.isWhitespace
            if !isSpace && !inWord { words += 1 }
            inWord = !isSpace
        }
        return words
    }

    /// What a list or post response says about each post, by canonical URL: the full word count
    /// (0 for discussion threads) and who may read it.
    private static func wordCounts(in data: Data) -> [String: Int] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        let posts: [[String: Any]]
        if let array = json as? [[String: Any]] {
            posts = array
        } else if let object = json as? [String: Any], let array = object["posts"] as? [[String: Any]] {
            posts = array
        } else {
            return [:]
        }
        var out: [String: Int] = [:]
        for post in posts {
            if let url = post["canonical_url"] as? String, let count = post["wordcount"] as? Int { out[url] = count }
        }
        return out
    }

    /// Is this post response only the paywall teaser? Substack answers a paid post with HTTP 200
    /// and the first few paragraphs when the session has no access (seen 17/11/2026 on
    /// slowboring.com: 57 words of a 2,422-word post), so the body is compared with `wordcount`.
    private static func isTeaser(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        let post = (object["post"] as? [String: Any]) ?? object
        guard let expected = post["wordcount"] as? Int, expected >= 100 else { return false }
        let body = (post["body_html"] as? String) ?? ""
        return wordCount(html: body) * 10 < expected * 7
    }

    /// "slowboring.com", "https://www.slowboring.com/p/x" or "matthewyglesias" -> an API host.
    static func host(fromFavourite text: String) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.isEmpty { return nil }
        if let range = value.range(of: "://") { value = String(value[range.upperBound...]) }
        if let slash = value.firstIndex(of: "/") { value = String(value[..<slash]) }
        if value.isEmpty { return nil }
        return value.contains(".") ? value : "\(value).substack.com"
    }

    /// The publication's Substack subdomain, read from its home page (a publication on its own
    /// domain still has one: slowboring.com is "matthewyglesias"). Needed to sign in there.
    private var subdomains: [String: String] = [:]
    private func subdomain(ofCustomHost host: String) async -> String? {
        if let known = subdomains[host] { return known }
        guard let url = URL(string: "https://\(host)/") else { return nil }
        do {
            try await limiter.wait()
            let (data, _) = try await session.data(from: url)
            let page = String(decoding: data, as: UTF8.self)
            guard let match = page.range(of: #"\\?"subdomain\\?":\\?"([a-z0-9-]+)"#, options: .regularExpression) else { return nil }
            let found = page[match].components(separatedBy: CharacterSet(charactersIn: "\"\\")).filter { !$0.isEmpty && $0 != "subdomain" && $0 != ":" }.last
            if let found { subdomains[host] = found }
            return found
        } catch {
            return nil
        }
    }

    /// One post, in full. Throws `previewOnly` when this sign-in only gets the paywall teaser.
    func fetchPost(canonicalURL: String) async throws -> Article {
        guard let url = SubstackEndpoints.post(forCanonicalURL: canonicalURL) else { throw FetchError.notHTTP }
        var json = try await get(url)
        if Self.isTeaser(json), let host = url.host, !host.hasSuffix("substack.com") {
            // A publication on its own domain: the substack.com session is not sent there.
            // Carry the sign-in over once, then ask again.
            if let subdomain = await subdomain(ofCustomHost: host),
               await SubstackDomainSession.shared.ensure(host: host, subdomain: subdomain) {
                json = try await get(url)
            }
        }
        if Self.isTeaser(json) { throw FetchError.previewOnly }
        return try SubstackParser.article(from: try SubstackParser.parsePost(json: json))
    }

    /// The posts of a listing worth fetching, newest first.
    private func candidates(from refs: [SubstackPostRef], words: [String: Int], oldest: Date,
                            seen: inout Set<ArticleID>, store: ArticleStore) async -> [(ref: SubstackPostRef, id: ArticleID)] {
        var out: [(ref: SubstackPostRef, id: ArticleID)] = []
        for ref in refs.sorted(by: { ($0.postDate ?? .distantPast) > ($1.postDate ?? .distantPast) }) {
            // UNVERIFIED: the values of `type`. Podcasts and threads have no article body.
            if let type = ref.type, ["podcast", "thread", "video"].contains(type) { continue }
            // Discussion threads and mailbag calls are newsletters with next to no words.
            if let count = words[ref.canonicalURL], count < 100 { continue }
            if let date = ref.postDate, date < oldest { continue }
            let id = ArticleID(canonicalURL: URLCanonicalizer.canonicalize(ref.canonicalURL))
            guard seen.insert(id).inserted, !unreadable.contains(id) else { continue }
            if await store.isKnown(id) { continue }
            out.append((ref, id))
        }
        return out
    }

    /// Discover and fetch new posts until done, cancelled, or `deadline` passes.
    func fetchNew(settings: AppSettings, store: ArticleStore, deadline: Date) async -> FetchSummary {
        var summary = FetchSummary()
        var favouriteRefs: [SubstackPostRef] = []
        var inboxRefs: [SubstackPostRef] = []
        var words: [String: Int] = [:]

        // Discovery 1: favourite publications, from their own archive.
        for text in settings.substackPublications {
            if Task.isCancelled || Date() >= deadline { break }
            guard let host = Self.host(fromFavourite: text), let url = SubstackEndpoints.archive(host: host) else { continue }
            do {
                let data = try await get(url)
                let found = try SubstackParser.parseList(json: data)
                words.merge(Self.wordCounts(in: data)) { $1 }
                favouriteRefs += found
                AppLog.post("Substack favourite \(host): \(found.count) post(s) listed")
            } catch {
                summary.notes.append("Substack \(host): \(error)")
            }
        }
        // Discovery 2: the reader inbox (every subscription).
        if settings.substackUseInbox, let url = SubstackEndpoints.inbox(limit: 20) {
            do {
                let data = try await get(url)
                let found = try SubstackParser.parseList(json: data)
                words.merge(Self.wordCounts(in: data)) { $1 }
                inboxRefs += found
                AppLog.post("Substack inbox: \(found.count) post(s)")
            } catch {
                summary.notes.append("Substack inbox: \(error)")
            }
        }

        // Newest first, text posts only, nothing we already know, nothing too old to keep.
        let oldest = Date().addingTimeInterval(-settings.unreadDays * 86_400)
        var seen = Set<ArticleID>()
        // Favourites go first and are not counted against the per-fetch limit.
        let favourites = await candidates(from: favouriteRefs, words: words, oldest: oldest, seen: &seen, store: store)
        let others = await candidates(from: inboxRefs, words: words, oldest: oldest, seen: &seen, store: store)
            .prefix(max(0, settings.substackMaxPerFetch))

        for (index, candidate) in (favourites + others).enumerated() {
            let isFavourite = index < favourites.count
            if Task.isCancelled || Date() >= deadline { break }
            do {
                var article: Article
                do {
                    article = try await fetchPost(canonicalURL: candidate.ref.canonicalURL)
                } catch FetchError.previewOnly {
                    unreadable.insert(candidate.id)
                    summary.failed += 1
                    summary.notes.append("\(candidate.ref.title): only the free preview is available to this sign-in")
                    continue
                }
                // Keep the id tied to the URL discovery used, so "already known" stays true.
                article.url = URLCanonicalizer.canonicalize(candidate.ref.canonicalURL)
                try await store.add(article, load: isFavourite && settings.autoLoadFavourites ? .load : .off)
                summary.added += 1
                AppLog.post("Substack stored: \(article.title) [\(candidate.ref.audience ?? "?")]")
            } catch let error as SubstackError {
                // No body: a paid post this session cannot read, or not a text post.
                unreadable.insert(candidate.id)
                summary.failed += 1
                summary.notes.append("\(candidate.ref.title): \(error)")
            } catch {
                summary.failed += 1
                summary.notes.append("\(candidate.ref.title): \(error)")
            }
        }
        return summary
    }
}
