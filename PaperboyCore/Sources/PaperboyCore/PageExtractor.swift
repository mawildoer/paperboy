import Foundation

public enum PageExtractorError: LocalizedError, Equatable, Sendable, CustomStringConvertible {
    /// The page has too little running text to be an article (a home page, a login wall, a video).
    case noArticleText(words: Int)

    public var errorDescription: String? {
        "Paperboy couldn’t find the article text. If you can open the full story on the publisher’s website, share that page from Safari."
    }

    public var description: String {
        switch self {
        case .noArticleText(let words): return "no article text found on the page (\(words) words)"
        }
    }
}

/// Turns the HTML of any web page into an `Article`: the title, site, author and date from the
/// page's metadata, and the body from its main content element. Used for pages shared to the app.
public enum PageExtractor {
    public static let minimumWords = 80

    public static func article(pageHTML html: String, url: String, sharedTitle: String? = nil, now: Date = Date(), useStructuredNYT: Bool = true) throws -> Article {
        let host = URLComponents(string: url)?.host?.lowercased() ?? ""
        // The New York Times ships the article as data in the page; that is cleaner than its markup.
        if useStructuredNYT, host.hasSuffix("nytimes.com"), let parsed = try? NYTParser.parse(pageHTML: html) {
            return parsed.article(fallbackURL: url, fetchedAt: now)
        }

        let meta = metaTags(in: html)
        let pageTitle = firstMatch(#"<title[^>]*>(.*?)</title>"#, in: html).map(HTMLCleaner.plainText)
        let title = firstNonEmpty(meta["og:title"], meta["twitter:title"], pageTitle, sharedTitle) ?? url
        let bareHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let source = firstNonEmpty(meta["og:site_name"], meta["application-name"]) ?? bareHost
        // `article:author` is often a profile URL, not a name.
        let author = firstNonEmpty(meta["author"], meta["article:author"].flatMap { $0.contains("://") ? nil : $0 }) ?? ""
        let date = firstNonEmpty(meta["article:published_time"], meta["og:article:published_time"], meta["date"])
            .flatMap(parseDate) ?? now

        let cleaned = HTMLCleaner.cleanWithImages(mainContent(of: html), baseURL: url)
        let body = cleaned.xhtml
        let words = HTMLCleaner.plainText(body).split(whereSeparator: \.isWhitespace).count
        guard words >= (cleaned.sources.isEmpty ? minimumWords : 10) else { throw PageExtractorError.noArticleText(words: words) }
        var article = Article(
            url: URLCanonicalizer.canonicalize(url), source: source, title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            author: author, date: date, bodyXHTML: body)
        article.imageSources = cleaned.sources
        return article
    }

    // MARK: Body

    /// The part of the page that holds the article: the `<article>` with the most text, else
    /// `<main>`, else `<body>`; with the page furniture inside it removed.
    static func mainContent(of html: String) -> String {
        var best = ""
        var bestLength = 0
        for block in blocks(named: "article", in: html) {
            let length = textLength(block)
            if length > bestLength {
                best = block
                bestLength = length
            }
        }
        if bestLength < 600 {
            for name in ["main", "body"] {
                if let block = blocks(named: name, in: html).max(by: { textLength($0) < textLength($1) }),
                   textLength(block) > bestLength
                {
                    best = block
                    bestLength = textLength(block)
                    break
                }
            }
        }
        if best.isEmpty { best = html }
        for name in ["header", "footer", "aside", "nav"] {
            best = removing(element: name, from: best)
        }
        return best
    }

    /// The outermost `<name …>…</name>` blocks, each from its opening tag to its matching close.
    static func blocks(named name: String, in html: String) -> [String] {
        var out: [String] = []
        let lower = html.lowercased()
        var search = lower.startIndex
        let open = "<\(name)"
        let close = "</\(name)"
        while let start = lower.range(of: open, range: search..<lower.endIndex) {
            // "<article" must not match "<articles".
            let after = lower[start.upperBound...].first
            guard after == ">" || after == " " || after == "\n" || after == "\t" || after == "/" else {
                search = start.upperBound
                continue
            }
            var depth = 1
            var cursor = start.upperBound
            var end: String.Index?
            while depth > 0 {
                let nextOpen = lower.range(of: open, range: cursor..<lower.endIndex)
                guard let nextClose = lower.range(of: close, range: cursor..<lower.endIndex) else { break }
                if let nextOpen, nextOpen.lowerBound < nextClose.lowerBound {
                    depth += 1
                    cursor = nextOpen.upperBound
                } else {
                    depth -= 1
                    cursor = nextClose.upperBound
                    if depth == 0 { end = nextClose.lowerBound }
                }
            }
            guard let end else {
                // Never closed: take the rest of the page.
                out.append(String(html[start.lowerBound...]))
                break
            }
            out.append(String(html[start.lowerBound..<end]))
            search = end
        }
        return out
    }

    static func removing(element name: String, from html: String) -> String {
        var result = html
        for block in blocks(named: name, in: html) {
            if let range = result.range(of: block) { result.removeSubrange(range) }
        }
        return result
    }

    /// Rough amount of running text: characters outside tags, scripts and styles.
    static func textLength(_ html: String) -> Int {
        var count = 0
        var inTag = false
        for scalar in html.unicodeScalars {
            if scalar == "<" { inTag = true } else if scalar == ">" { inTag = false } else if !inTag { count += 1 }
        }
        // Scripts and styles carry text between their tags; a page of them is not an article.
        let scripts = blocks(named: "script", in: html).reduce(0) { $0 + $1.count }
            + blocks(named: "style", in: html).reduce(0) { $0 + $1.count }
        return max(0, count - scripts)
    }

    // MARK: Metadata

    /// `<meta property|name="key" content="value">`, in either attribute order, keys lowercased.
    static func metaTags(in html: String) -> [String: String] {
        var out: [String: String] = [:]
        guard let tag = try? NSRegularExpression(pattern: "<meta\\b[^>]*>", options: [.caseInsensitive]),
              let attribute = try? NSRegularExpression(pattern: "([a-zA-Z:-]+)\\s*=\\s*(\"([^\"]*)\"|'([^']*)')")
        else { return out }
        // Metadata lives in the head; do not scan a multi-megabyte body for it.
        let head = String(html.prefix(200_000))
        let text = head as NSString
        for match in tag.matches(in: head, range: NSRange(location: 0, length: text.length)) {
            let element = text.substring(with: match.range) as NSString
            var attributes: [String: String] = [:]
            for found in attribute.matches(in: element as String, range: NSRange(location: 0, length: element.length)) {
                let key = element.substring(with: found.range(at: 1)).lowercased()
                let valueRange = found.range(at: 3).location != NSNotFound ? found.range(at: 3) : found.range(at: 4)
                attributes[key] = element.substring(with: valueRange)
            }
            guard let key = (attributes["property"] ?? attributes["name"])?.lowercased(),
                  let content = attributes["content"], out[key] == nil else { continue }
            let value = HTMLCleaner.plainText(content).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { out[key] = value }
        }
        return out
    }

    static func firstMatch(_ pattern: String, in html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        let head = String(html.prefix(200_000))
        let text = head as NSString
        guard let match = regex.firstMatch(in: head, range: NSRange(location: 0, length: text.length)), match.numberOfRanges > 1 else { return nil }
        return text.substring(with: match.range(at: 1))
    }

    static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            if let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    static func parseDate(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(identifier: "UTC")
        day.dateFormat = "yyyy-MM-dd"
        return day.date(from: String(text.prefix(10)))
    }
}

/// One page shared to the app from the share sheet, as the share extension writes it.
public struct SharedPage: Codable, Sendable, Equatable {
    public var url: String
    public var title: String?
    /// The page as the browser showed it (Safari only); nil when only the link was shared.
    public var html: String?
    public var pdfFile: String?
    public var sharedAt: Date
    /// How many times turning it into an article has failed.
    public var attempts: Int

    public init(url: String, title: String? = nil, html: String? = nil, sharedAt: Date = Date(), attempts: Int = 0, pdfFile: String? = nil) {
        self.pdfFile = pdfFile
        self.url = url
        self.title = title
        self.html = html
        self.sharedAt = sharedAt
        self.attempts = attempts
    }

    private enum CodingKeys: String, CodingKey {
        case url, title, html, sharedAt, attempts, pdfFile
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pdfFile = try c.decodeIfPresent(String.self, forKey: .pdfFile)
        url = try c.decode(String.self, forKey: .url)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        html = try c.decodeIfPresent(String.self, forKey: .html)
        // The extension writes seconds since 1970.
        sharedAt = Date(timeIntervalSince1970: try c.decodeIfPresent(Double.self, forKey: .sharedAt) ?? 0)
        attempts = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(pdfFile, forKey: .pdfFile)
        try c.encode(url, forKey: .url)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(html, forKey: .html)
        try c.encode(sharedAt.timeIntervalSince1970, forKey: .sharedAt)
        try c.encode(attempts, forKey: .attempts)
    }
}
