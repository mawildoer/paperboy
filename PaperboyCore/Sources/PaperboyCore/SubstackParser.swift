import Foundation

/// Every Substack URL the app uses, in one place, so they can be corrected after testing on the
/// phone. None of these are officially documented.
public enum SubstackEndpoints {
    /// The sign-in page shown in the login web view.
    public static let signIn = URL(string: "https://substack.com/sign-in")

    /// The reader inbox of the signed-in user (posts from all subscriptions, newest first).
    /// Verified on 15/11/2026: returns `{"posts": [...], "inboxItems": [...], "cursor", "more"}`
    /// and each post carries `body_html`. Without `inboxType`, or with limit 30, it answers HTTP 400;
    /// limit 20 works.
    public static func inbox(limit: Int) -> URL? {
        URL(string: "https://substack.com/api/v1/reader/posts?inboxType=inbox&limit=\(min(20, max(1, limit)))")
    }

    /// UNVERIFIED: the signed-in user's subscriptions. Believed to return
    /// `{"subscriptions": [...], "publications": [{"subdomain": ..., "custom_domain": ...}]}`.
    public static let subscriptions = URL(string: "https://substack.com/api/v1/subscriptions")

    /// A publication's archive, newest first. Verified on 17/11/2026 against slowboring.com:
    /// returns `{"posts": [...], "nextCursor": "..."}` with `wordcount` and `audience` per post
    /// and no body. `offset` is refused with HTTP 400 ("Invalid value"), so it is not sent.
    /// A `<subdomain>.substack.com` host redirects to the publication's own domain.
    public static func archive(host: String, limit: Int = 12) -> URL? {
        URL(string: "https://\(host)/api/v1/archive?sort=new&limit=\(max(1, limit))")
    }

    /// One post with its full `body_html` (full only if the session cookie belongs to a
    /// subscriber with access). UNVERIFIED for custom domains: the session cookie is set for
    /// substack.com, so a publication on its own domain may need a separate sign-in.
    public static func post(host: String, slug: String) -> URL? {
        guard let encoded = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://\(host)/api/v1/posts/\(encoded)")
    }

    /// The post JSON endpoint for a post's public URL (`https://host/p/slug`).
    public static func post(forCanonicalURL url: String) -> URL? {
        guard let components = URLComponents(string: url), let host = components.host else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        guard let marker = parts.firstIndex(of: "p"), marker + 1 < parts.count else { return nil }
        return post(host: host, slug: parts[marker + 1])
    }

    /// Cookie names that indicate a signed-in Substack session. UNVERIFIED.
    public static let sessionCookieNames: Set<String> = ["substack.sid", "connect.sid"]
}

public struct SubstackPost: Sendable, Equatable {
    public var title: String
    public var subtitle: String?
    public var canonicalURL: String
    public var slug: String?
    public var postDate: Date?
    public var bodyHTML: String?
    public var authors: [String]
    /// "everyone", "only_paid", "founding", …
    public var audience: String?
    public var publicationName: String?

    /// Host of the canonical URL, e.g. "example.substack.com".
    public var host: String? { URLComponents(string: canonicalURL)?.host }
}

/// A post as it appears in a list (archive or inbox): enough to decide whether to fetch it.
public struct SubstackPostRef: Sendable, Equatable {
    public var title: String
    public var canonicalURL: String
    public var slug: String?
    public var postDate: Date?
    public var audience: String?
    /// "newsletter", "podcast", "thread", … when present.
    public var type: String?

    public var host: String? { URLComponents(string: canonicalURL)?.host }
}

public enum SubstackError: Error, Equatable, Sendable, CustomStringConvertible {
    case notJSON(String)
    case notAPost
    /// The JSON has no `body_html`: not a text post, or the session has no access to it.
    case noBody(audience: String?)

    public var description: String {
        switch self {
        case .notJSON(let detail): return "Substack did not return JSON (\(detail))"
        case .notAPost: return "the Substack response does not look like a post"
        case .noBody(let audience): return "the post has no body (audience: \(audience ?? "unknown")); is the session signed in?"
        }
    }
}

public enum SubstackParser {
    // MARK: Post

    public static func parsePost(json data: Data) throws -> SubstackPost {
        let root: JSONValue
        do { root = try JSONValue.parse(data) } catch { throw SubstackError.notJSON(String(describing: error)) }
        // Some endpoints wrap the post: {"post": {...}}.
        let candidates = [root, root["post"]].compactMap { $0 }
        for candidate in candidates {
            if let post = post(from: candidate) { return post }
        }
        throw SubstackError.notAPost
    }

    private static func post(from value: JSONValue) -> SubstackPost? {
        guard value.objectValue != nil else { return nil }
        guard let url = value["canonical_url"]?.stringValue, !url.isEmpty else { return nil }
        let title = value["title"]?.stringValue ?? ""
        let subtitle = value["subtitle"]?.stringValue
        var authors: [String] = []
        for byline in value["publishedBylines"]?.arrayValue ?? [] {
            if let name = byline["name"]?.stringValue?.trimmingCharacters(in: .whitespaces), !name.isEmpty, !authors.contains(name) {
                authors.append(name)
            }
        }
        var publication = value["publication"]?["name"]?.stringValue
        if publication == nil {
            // UNVERIFIED: bylines sometimes carry the publication they write for.
            for byline in value["publishedBylines"]?.arrayValue ?? [] {
                for membership in byline["publicationUsers"]?.arrayValue ?? [] {
                    if let name = membership["publication"]?["name"]?.stringValue, !name.isEmpty {
                        publication = name
                        break
                    }
                }
                if publication != nil { break }
            }
        }
        let body = value["body_html"]?.stringValue
        return SubstackPost(
            title: title,
            subtitle: (subtitle?.isEmpty ?? true) ? nil : subtitle,
            canonicalURL: url,
            slug: value["slug"]?.stringValue,
            postDate: value["post_date"]?.stringValue.flatMap(ISODate.parse),
            bodyHTML: (body?.isEmpty ?? true) ? nil : body,
            authors: authors,
            audience: value["audience"]?.stringValue,
            publicationName: publication)
    }

    // MARK: Lists

    /// Decode an archive or inbox response into post references. Items that are not posts
    /// (no canonical URL) are skipped; duplicates are removed, order is kept.
    public static func parseList(json data: Data) throws -> [SubstackPostRef] {
        let root: JSONValue
        do { root = try JSONValue.parse(data) } catch { throw SubstackError.notJSON(String(describing: error)) }
        var items: [JSONValue] = []
        if let array = root.arrayValue {
            items = array
        } else {
            for key in ["posts", "items", "inboxItems", "results"] {
                if let array = root[key]?.arrayValue {
                    items = array
                    break
                }
            }
        }
        var seen = Set<String>()
        var refs: [SubstackPostRef] = []
        for item in items {
            // Inbox items may nest the post.
            let candidates = [item, item["post"], item["content"]].compactMap { $0 }
            for candidate in candidates {
                guard let url = candidate["canonical_url"]?.stringValue ?? candidate["web_url"]?.stringValue, !url.isEmpty else { continue }
                guard seen.insert(url).inserted else { break }
                refs.append(
                    SubstackPostRef(
                        title: candidate["title"]?.stringValue ?? "",
                        canonicalURL: url,
                        slug: candidate["slug"]?.stringValue,
                        postDate: (candidate["post_date"]?.stringValue ?? candidate["published_at"]?.stringValue ?? candidate["created_at"]?.stringValue)
                            .flatMap(ISODate.parse),
                        audience: candidate["audience"]?.stringValue,
                        type: candidate["type"]?.stringValue))
                break
            }
        }
        return refs
    }

    /// Hosts of the publications in a subscriptions response (custom domain if there is one,
    /// else `<subdomain>.substack.com`).
    public static func parsePublicationHosts(json data: Data) throws -> [String] {
        let root: JSONValue
        do { root = try JSONValue.parse(data) } catch { throw SubstackError.notJSON(String(describing: error)) }
        var publications: [JSONValue] = root["publications"]?.arrayValue ?? []
        if publications.isEmpty {
            for subscription in root["subscriptions"]?.arrayValue ?? root.arrayValue ?? [] {
                if let publication = subscription["publication"] { publications.append(publication) }
            }
        }
        var hosts: [String] = []
        for publication in publications {
            var host: String?
            if let custom = publication["custom_domain"]?.stringValue, !custom.isEmpty {
                host = custom
            } else if let subdomain = publication["subdomain"]?.stringValue, !subdomain.isEmpty {
                host = "\(subdomain).substack.com"
            }
            if let host = host?.lowercased(), !hosts.contains(host) { hosts.append(host) }
        }
        return hosts
    }

    // MARK: Article

    /// Clean a post into an `Article`. Throws `.noBody` if there is nothing to read.
    public static func article(from post: SubstackPost, fetchedAt: Date = Date()) throws -> Article {
        guard let html = post.bodyHTML else { throw SubstackError.noBody(audience: post.audience) }
        var body = ""
        if let subtitle = post.subtitle {
            body += "<p><em>\(HTMLCleaner.escape(subtitle))</em></p>\n"
        }
        body += HTMLCleaner.clean(html)
        let url = URLCanonicalizer.canonicalize(post.canonicalURL)
        return Article(
            url: url,
            source: post.publicationName ?? post.host ?? "Substack",
            title: post.title.isEmpty ? "Untitled" : post.title,
            author: post.authors.joined(separator: ", "),
            date: post.postDate ?? fetchedAt,
            bodyXHTML: body)
    }
}
