import Foundation

/// Selects an importer. Each publisher checks access when it reads the shared article.
public enum SharedPublisher: String, Codable, Sendable, Equatable {
    case economist, nyt, medium, substack

    /// Snapshot metadata applies only to the supplied page. The caller can retain the result
    /// alongside the original article URL after a successful import.
    public static func identify(_ url: URL, sharedHTML: String?, substackPublications: [String]) -> Self? {
        guard url.pathExtension.lowercased() != "pdf", let host = webHost(url) else { return nil }
        if EconomistDiscovery.isPublisherHost(host) || host == "econ.st" { return .economist }
        if host == "nyti.ms" || host == "nytimes.com" || host.hasSuffix(".nytimes.com") { return .nyt }
        if let publisher = platform(host: host) { return publisher }

        if substackPublications.contains(where: { matchesFavourite($0, host: host) }) { return .substack }
        guard let sharedHTML else { return nil }
        return publisherInHead(sharedHTML)
    }

    /// Read the encoded DNS authority so escaped delimiters and malformed host labels cannot
    /// become publisher suffixes. Foundation represents internationalized names in IDNA form.
    private static func webHost(_ url: URL) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", parts.user == nil, parts.password == nil,
              parts.rangeOfPort == nil || parts.port == 443,
              let host = parts.encodedHost?.lowercased(), host.utf8.count <= 253,
              host.wholeMatch(of: #/(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?/#) != nil
        else { return nil }
        return host
    }

    private static func platform(host: String) -> Self? {
        if MediumDiscovery.isMediumHost(host) { return .medium }
        if host == "substack.com" || host.hasSuffix(".substack.com") { return .substack }
        return nil
    }

    private static func matchesFavourite(_ favourite: String, host: String) -> Bool {
        // A bare publication nickname already falls under *.substack.com.
        let text = favourite.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = text.contains("://") ? text : "https://\(text)"
        guard let url = URL(string: address), let configured = webHost(url) else { return false }
        return configured == host || "www." + configured == host || configured == "www." + host
    }

    private static func publisherInHead(_ html: String) -> Self? {
        // Inspect direct head children only. Shared snapshots can also contain a head fragment.
        // Tokenize until the body begins, including when a large inline script precedes the tags.
        var tokenizer = HTMLTokenizer(html)
        var inHead = false
        var found: Self?
        while let token = tokenizer.next() {
            switch token {
            case .start("html", _): continue
            case .start("head", _): inHead = true
            case .end("head"), .start("body", _), .end("html"): return found
            case .start(let name, let attrs) where name == "meta" || name == "link":
                guard let hint = metadataPublisher(name, attributes: attrs) else { continue }
                if let found, found != hint { return nil }
                found = hint
            case .start(let name, _):
                guard inHead || ["title", "base", "noscript", "template"].contains(name) else { return found }
                guard !HTMLTreeBuilder.voidElements.contains(name) else { continue }
                // Ignore the entire element, including literal markup inside a title or template.
                var depth = 1
                while depth > 0, let child = tokenizer.next() {
                    switch child {
                    case .start(name, _): depth += 1
                    case .end(name): depth -= 1
                    default: continue
                    }
                }
            case .text(let text) where !inHead && !text.allSatisfy(\.isWhitespace): return found
            default: continue
            }
        }
        return found
    }

    private static func metadataPublisher(_ tag: String, attributes attrs: [String: String]) -> Self? {
        if tag == "link" {
            let rel = (attrs["rel"] ?? "").lowercased().split(whereSeparator: \.isWhitespace)
            let feed = rel.contains("alternate") && attrs["type"]?.lowercased() == "application/rss+xml"
            guard rel.contains("canonical") || feed, let href = attrs["href"],
                  let url = URL(string: href.hasPrefix("//") ? "https:" + href : href),
                  let host = webHost(url) else { return nil }
            return platform(host: host)
        }

        guard let key = (attrs["property"] ?? attrs["name"])?.lowercased(),
              let content = attrs["content"]?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        switch key {
        case "generator", "al:ios:app_name", "al:android:app_name", "twitter:app:name:iphone", "twitter:app:name:googleplay":
            switch content.lowercased() {
            case "medium": return .medium
            case "substack": return .substack
            default: return nil
            }
        case "al:ios:url", "al:android:url", "twitter:app:url:iphone", "twitter:app:url:googleplay":
            guard let url = URL(string: content) else { return nil }
            if let host = webHost(url) { return platform(host: host) }
            guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  parts.user == nil, parts.password == nil, parts.rangeOfPort == nil,
                  let command = parts.encodedHost, command.wholeMatch(of: #/[a-z0-9-]+/#) != nil else { return nil }
            switch parts.scheme?.lowercased() {
            case "medium" where command == "p" && !parts.path.isEmpty: return .medium
            case "substack": return .substack
            default: return nil
            }
        case "al:ios:app_store_id", "twitter:app:id:iphone":
            return appStorePublisher(id: content)
        case "apple-itunes-app":
            for field in content.split(separator: ",") {
                let pair = field.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if pair.count == 2, pair[0].lowercased() == "app-id" { return appStorePublisher(id: pair[1]) }
            }
            return nil
        default: return nil
        }
    }

    private static func appStorePublisher(id: String) -> Self? {
        switch id {
        case "828256236": .medium
        case "1581650857": .substack
        default: nil
        }
    }
}
