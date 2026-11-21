import Foundation

public enum NYTError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The page is DataDome's bot check (captcha-delivery.com), not an article.
    case captcha
    /// No `window.__preloadedData` in the page.
    case noPreloadedData
    case malformedData(String)
    /// The data has no article with a body: a live blog, an interactive, a video page…
    case noArticle
    /// An article was found but its body produced no text.
    case emptyBody

    public var description: String {
        switch self {
        case .captcha: return "NYT returned a bot-check (DataDome captcha) page"
        case .noPreloadedData: return "the NYT page has no __preloadedData"
        case .malformedData(let detail): return "could not decode NYT __preloadedData (\(detail))"
        case .noArticle: return "the NYT page has no article body (live blog or interactive?)"
        case .emptyBody: return "the NYT article body is empty"
        }
    }
}

public struct NYTArticle: Sendable, Equatable {
    public var headline: String
    /// "Jane Doe and John Roe", without the leading "By".
    public var byline: String
    public var firstPublished: Date?
    public var url: String?
    public var summary: String?
    /// Cleaned XHTML (same vocabulary as `HTMLCleaner`).
    public var bodyXHTML: String

    public func article(fallbackURL: String, fetchedAt: Date = Date()) -> Article {
        Article(
            url: URLCanonicalizer.canonicalize(url ?? fallbackURL),
            source: "The New York Times",
            title: headline.isEmpty ? "Untitled" : headline,
            author: byline,
            date: firstPublished ?? fetchedAt,
            bodyXHTML: bodyXHTML)
    }
}

/// Reads an article out of the `window.__preloadedData = {...};` script of an NYT article page.
/// The structure mirrors Calibre's `nytimes.py` site parser, including its tolerance: the body
/// is walked generically, so unknown block types contribute whatever text they contain.
public enum NYTParser {
    /// JavaScript that returns the data as text; evaluated in the hidden web view.
    /// `JSON.stringify` drops `undefined`, so the result is plain JSON.
    public static let extractionJavaScript = """
        (function () {
          try {
            if (window.__preloadedData) { return JSON.stringify(window.__preloadedData); }
          } catch (e) {}
          var scripts = document.getElementsByTagName('script');
          for (var i = 0; i < scripts.length; i++) {
            var t = scripts[i].textContent || '';
            if (t.indexOf('window.__preloadedData') !== -1) { return t; }
          }
          if (document.documentElement.outerHTML.indexOf('captcha-delivery.com') !== -1) { return '__PAPERBOY_CAPTCHA__'; }
          return '';
        })()
        """

    // MARK: Entry points

    /// Parse a whole article page (HTML).
    public static func parse(pageHTML: String) throws -> NYTArticle {
        guard let marker = pageHTML.range(of: "window.__preloadedData") else {
            if looksLikeCaptcha(pageHTML) { throw NYTError.captcha }
            throw NYTError.noPreloadedData
        }
        let rest = pageHTML[marker.lowerBound...]
        let end = rest.range(of: "</script", options: .caseInsensitive)?.lowerBound ?? rest.endIndex
        return try parse(preloadedData: String(rest[..<end]))
    }

    /// Parse the script text (`window.__preloadedData = {...};`), the bare object literal, or the
    /// output of `JSON.stringify(window.__preloadedData)`.
    public static func parse(preloadedData script: String) throws -> NYTArticle {
        guard let brace = script.firstIndex(of: "{") else {
            if looksLikeCaptcha(script) { throw NYTError.captcha }
            throw NYTError.noPreloadedData
        }
        let literal = sanitizeJavaScriptLiteral(String(script[brace...]))
        let data: JSONValue
        do {
            data = try JSONValue.parse(literal)
        } catch {
            if looksLikeCaptcha(script) { throw NYTError.captcha }
            throw NYTError.malformedData(String(describing: error))
        }
        return try article(from: data)
    }

    public static func looksLikeCaptcha(_ text: String) -> Bool {
        if text.contains("__PAPERBOY_CAPTCHA__") { return true }
        let lower = text.lowercased()
        return lower.contains("captcha-delivery.com") || (lower.contains("datadome") && !lower.contains("__preloadeddata"))
    }

    /// Replace bare `undefined` (outside string literals) with `null`, so that a JavaScript
    /// object literal becomes JSON.
    public static func sanitizeJavaScriptLiteral(_ text: String) -> String {
        let bytes = Array(text.utf8)
        let word = Array("undefined".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var inString = false
        var i = 0
        func isIdentifierByte(_ b: UInt8) -> Bool {
            (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 95 || b == 36 || b >= 0x80
        }
        while i < bytes.count {
            let b = bytes[i]
            if inString {
                out.append(b)
                if b == UInt8(ascii: "\\"), i + 1 < bytes.count {
                    out.append(bytes[i + 1])
                    i += 2
                    continue
                }
                if b == UInt8(ascii: "\"") { inString = false }
                i += 1
                continue
            }
            if b == UInt8(ascii: "\"") {
                inString = true
                out.append(b)
                i += 1
                continue
            }
            if b == word[0], i + word.count <= bytes.count, Array(bytes[i..<(i + word.count)]) == word,
               i == 0 || !isIdentifierByte(bytes[i - 1]),
               i + word.count == bytes.count || !isIdentifierByte(bytes[i + word.count])
            {
                out.append(contentsOf: Array("null".utf8))
                i += word.count
                continue
            }
            out.append(b)
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: Locating the article

    public static func article(from data: JSONValue) throws -> NYTArticle {
        let cache = data["initialState"]
        guard let article = locateArticle(in: data, cache: cache) else { throw NYTError.noArticle }
        let walker = BodyWalker(cache: cache)
        let body = walker.resolve(article["sprinkledBody"] ?? .null)
        var html = ""
        for block in body["content"]?.arrayValue ?? [] {
            html += walker.html(for: block, depth: 0)
            html += "\n"
        }
        let xhtml = HTMLCleaner.clean(html)
        guard !xhtml.isEmpty else { throw NYTError.emptyBody }

        var headline = text(of: article["headline"], walker: walker)
        if headline.isEmpty {
            // Fall back to the headline inside the body's header block.
            for block in body["content"]?.arrayValue ?? [] {
                let resolved = walker.resolve(block)
                if (resolved["__typename"]?.stringValue ?? "").contains("Header"), let h = resolved["headline"] {
                    headline = HTMLCleaner.plainText(walker.html(for: h, depth: 0))
                    if !headline.isEmpty { break }
                }
            }
        }
        return NYTArticle(
            headline: headline,
            byline: byline(of: article, walker: walker),
            firstPublished: (article["firstPublished"]?.stringValue ?? article["publishedAt"]?.stringValue).flatMap(ISODate.parse),
            url: article["url"]?.stringValue,
            summary: article["summary"]?.stringValue,
            bodyXHTML: xhtml)
    }

    private static func hasBody(_ value: JSONValue, cache: JSONValue?) -> Bool {
        guard let body = value["sprinkledBody"] else { return false }
        let resolved = BodyWalker(cache: cache).resolve(body)
        return resolved["content"]?.arrayValue != nil
    }

    private static func locateArticle(in data: JSONValue, cache: JSONValue?) -> JSONValue? {
        // The documented places first: NYT has used both, and both keys are usually present.
        for key in ["initialData", "loaderData"] {
            if let article = data.at(key, "data", "article"), hasBody(article, cache: cache) { return article }
        }
        // Then anywhere: loaderData keyed by route, the Apollo cache under initialState, …
        var found: JSONValue?
        var budget = 200_000
        func search(_ value: JSONValue, depth: Int) {
            guard found == nil, depth < 12, budget > 0 else { return }
            budget -= 1
            switch value {
            case .object(let object):
                if hasBody(value, cache: cache) {
                    found = value
                    return
                }
                for (_, member) in object.members { search(member, depth: depth + 1) }
            case .array(let items):
                for item in items { search(item, depth: depth + 1) }
            default:
                break
            }
        }
        search(data, depth: 0)
        return found
    }

    private static func text(of value: JSONValue?, walker: BodyWalker) -> String {
        guard let value else { return "" }
        if let s = value.stringValue { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        let resolved = walker.resolve(value)
        if let s = resolved["default"]?.stringValue { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        return HTMLCleaner.plainText(walker.html(for: resolved, depth: 0))
    }

    private static func byline(of article: JSONValue, walker: BodyWalker) -> String {
        var names: [String] = []
        for entry in article["bylines"]?.arrayValue ?? [] {
            let byline = walker.resolve(entry)
            if let rendered = byline["renderedRepresentation"]?.stringValue {
                var text = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.lowercased().hasPrefix("by ") { text.removeFirst(3) }
                if !text.isEmpty { names.append(text) }
                continue
            }
            for creator in byline["creators"]?.arrayValue ?? [] {
                if let name = walker.resolve(creator)["displayName"]?.stringValue, !name.isEmpty { names.append(name) }
            }
        }
        return names.joined(separator: ", ")
    }

    // MARK: Body

    /// Converts body blocks to loose HTML with escaped text; `HTMLCleaner` then makes it tidy.
    struct BodyWalker {
        let cache: JSONValue?

        static let skipped: Set<String> = [
            "RelatedLinksBlock", "EmailSignupBlock", "Dropzone", "AudioBlock", "CommentsBlock", "BylineBlock",
            "TimestampBlock", "LabelBlock", "Video", "VideoBlock", "EmbeddedInteractive", "InteractiveBlock",
            "YouTubeEmbedBlock", "TwitterEmbedBlock", "InstagramEmbedBlock", "SoundcloudEmbedBlock", "SpotifyEmbedBlock",
            "AdBlock", "Slideshow", "SlideshowBlock", "CapsuleBlock", "UnstructuredBlock",
        ]

        /// Follow an Apollo cache reference (`{"__ref": "..."}` or `{"type": "id", "id": "..."}`).
        func resolve(_ value: JSONValue) -> JSONValue {
            guard let cache, let object = value.objectValue, object["__typename"] == nil else { return value }
            var key: String?
            if let ref = object["__ref"]?.stringValue {
                key = ref
            } else if object.count <= 4, let id = object["id"]?.stringValue, object["content"] == nil, object["text"] == nil {
                key = id
            }
            if let key, let target = cache[key] { return target }
            return value
        }

        func html(for raw: JSONValue, depth: Int) -> String {
            guard depth < 60 else { return "" }
            let block = resolve(raw)
            guard block.objectValue != nil else { return "" }
            let typename = block["__typename"]?.stringValue ?? ""

            if typename.contains("Header") {
                // Headline, byline and timestamp are EPUB metadata; keep only the summary.
                if let summary = block["summary"] {
                    let inner = html(for: summary, depth: depth + 1)
                    return inner.isEmpty ? "" : "<p><i>\(inner)</i></p>"
                }
                return ""
            }
            if typename.hasPrefix("Heading") {
                var level = 2
                if let digit = typename.unicodeScalars.first(where: { $0.value >= 49 && $0.value <= 54 }) {
                    level = Int(digit.value) - 48
                } else if let n = block["level"]?.numberValue, n >= 1, n <= 6 {
                    level = Int(n)
                }
                return "<h\(level)>\(contents(of: block, depth: depth))</h\(level)>"
            }
            switch typename {
            case "ParagraphBlock", "DetailBlock", "TextRunKV":
                return "<p>\(contents(of: block, depth: depth))</p>"
            case "BlockquoteBlock", "PullquoteBlock":
                return "<blockquote>\(contents(of: block, depth: depth))</blockquote>"
            case "LineBreakInline":
                return "<br/>"
            case "RuleBlock":
                return "<hr/>"
            case "ListBlock":
                let style = (block["style"]?.stringValue ?? block["listStyle"]?.stringValue ?? "").uppercased()
                let tag = (style.contains("ORDERED") && !style.contains("UNORDERED")) || style.contains("NUMBER") ? "ol" : "ul"
                return "<\(tag)>\(contents(of: block, depth: depth))</\(tag)>"
            case "ListItemBlock":
                return "<li>\(contents(of: block, depth: depth))</li>"
            case "Image":
                return imageCaption(block, depth: depth)
            case "ImageBlock":
                // The image itself usually sits under "media".
                return imageCaption(block["media"].map(resolve) ?? block, depth: depth)
            case "GridBlock":
                if let caption = block["caption"]?.stringValue, !caption.isEmpty {
                    return "<figcaption>\(HTMLCleaner.escape(caption))</figcaption>"
                }
                return ""
            default:
                if typename.isEmpty || Self.skipped.contains(typename) {
                    // Calibre ignores untyped objects too; typed-but-unknown ones are walked.
                    return typename.isEmpty ? contents(of: block, depth: depth) : ""
                }
                return contents(of: block, depth: depth)
            }
        }

        /// Calibre's `parse_cnt`: walk every member in order; arrays and objects are content.
        func contents(of block: JSONValue, depth: Int) -> String {
            guard let object = block.objectValue else { return "" }
            var out = ""
            for (key, value) in object.members {
                switch value {
                case .array(let items):
                    if key == "formats" {
                        out += formatted(block)
                    } else {
                        for item in items { out += html(for: item, depth: depth + 1) }
                    }
                case .object:
                    out += html(for: value, depth: depth + 1)
                default:
                    break
                }
            }
            if object["formats"]?.arrayValue == nil, object["content"] == nil, let text = object["text"]?.stringValue {
                out += HTMLCleaner.escape(text)
            }
            return out
        }

        /// A TextInline: its text wrapped in its formats.
        private func formatted(_ inline: JSONValue) -> String {
            var open = ""
            var close = ""
            for format in inline["formats"]?.arrayValue ?? [] {
                switch resolve(format)["__typename"]?.stringValue ?? "" {
                case "BoldFormat":
                    open += "<strong>"
                    close = "</strong>" + close
                case "ItalicFormat":
                    open += "<em>"
                    close = "</em>" + close
                case "LinkFormat":
                    if let url = resolve(format)["url"]?.stringValue {
                        open += "<a href=\"\(HTMLCleaner.escape(url))\">"
                        close = "</a>" + close
                    }
                default:
                    break
                }
            }
            return open + HTMLCleaner.escape(inline["text"]?.stringValue ?? "") + close
        }

        private func imageCaption(_ image: JSONValue, depth: Int) -> String {
            var caption = ""
            if let value = image["caption"] {
                if let text = value.stringValue {
                    caption = HTMLCleaner.escape(text)
                } else {
                    caption = html(for: value, depth: depth + 1)
                }
            } else if let legacy = image["legacyHtmlCaption"]?.stringValue {
                caption = legacy  // already HTML; the cleaner flattens it to text
            }
            guard !HTMLCleaner.plainText(caption).isEmpty else { return "" }
            if let credit = image["credit"]?.stringValue, !credit.isEmpty {
                caption += " " + HTMLCleaner.escape(credit)
            }
            return "<figcaption>\(caption)</figcaption>"
        }
    }
}

// MARK: - Discovery

public struct FeedItem: Sendable, Equatable {
    public var url: String
    public var title: String
    public var date: Date?

    public init(url: String, title: String, date: Date?) {
        self.url = url
        self.title = title
        self.date = date
    }
}

public enum NYTDiscovery {
    /// Section fronts and feeds used when the user has not configured any.
    public static let defaultFeeds = [
        "https://rss.nytimes.com/services/xml/rss/nyt/HomePage.xml"
    ]

    public static let loginURL = URL(string: "https://myaccount.nytimes.com/auth/login")

    /// Cookie names that indicate a signed-in NYT session. UNVERIFIED.
    public static let sessionCookieNames: Set<String> = ["NYT-S", "SIDNY"]

    /// Is this URL an ordinary article (dated path ending in .html, not interactive/live/video)?
    public static func isArticleURL(_ url: String) -> Bool {
        guard let components = URLComponents(string: url), let host = components.host?.lowercased(),
              host == "www.nytimes.com" || host == "nytimes.com"
        else { return false }
        let path = components.path
        for excluded in ["/interactive/", "/live/", "/video/", "/podcasts/", "/crosswords/", "/games/", "/slideshow/", "/athletic/"] {
            if path.contains(excluded) { return false }
        }
        guard path.hasSuffix(".html") else { return false }
        let parts = path.split(separator: "/")
        guard parts.count >= 5, parts[0].count == 4, Int(parts[0]) != nil, Int(parts[1]) != nil, Int(parts[2]) != nil else {
            return false
        }
        return true
    }

    /// Items of an RSS 2.0 or Atom feed.
    public static func parseFeed(_ data: Data) -> [FeedItem] {
        let delegate = FeedParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        parser.parse()
        var seen = Set<String>()
        return delegate.items.filter { seen.insert($0.url).inserted }
    }

    /// Article links found in a section page's HTML, in page order, without duplicates.
    public static func articleLinks(inSectionHTML html: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "href\\s*=\\s*[\"']([^\"'#?]+\\.html)[\"'#?]") else { return [] }
        var seen = Set<String>()
        var links: [String] = []
        let range = NSRange(html.startIndex..., in: html)
        for match in regex.matches(in: html, range: range) {
            guard match.numberOfRanges > 1, let captured = Range(match.range(at: 1), in: html) else { continue }
            var link = String(html[captured])
            if link.hasPrefix("/") { link = "https://www.nytimes.com" + link }
            let canonical = URLCanonicalizer.canonicalize(link)
            if isArticleURL(canonical), seen.insert(canonical).inserted { links.append(canonical) }
        }
        return links
    }

    static func parseFeedDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.date(from: trimmed) ?? ISODate.parse(trimmed)
    }

    private final class FeedParserDelegate: NSObject, XMLParserDelegate {
        var items: [FeedItem] = []
        private var inItem = false
        private var text = ""
        private var link = ""
        private var title = ""
        private var date: Date?

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
            attributes: [String: String]
        ) {
            text = ""
            if elementName == "item" || elementName == "entry" {
                inItem = true
                link = ""
                title = ""
                date = nil
            } else if inItem, elementName == "link", let href = attributes["href"], link.isEmpty {
                link = href  // Atom
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            text += String(decoding: CDATABlock, as: UTF8.self)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            guard inItem else { return }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch elementName {
            case "link": if !value.isEmpty { link = value }
            case "title": title = value
            case "pubDate", "published", "updated", "dc:date": if date == nil { date = NYTDiscovery.parseFeedDate(value) }
            case "item", "entry":
                inItem = false
                if !link.isEmpty {
                    items.append(FeedItem(url: URLCanonicalizer.canonicalize(link), title: title, date: date))
                }
            default: break
            }
            text = ""
        }
    }
}
