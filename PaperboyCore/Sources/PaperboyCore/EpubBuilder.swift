import Foundation

/// One article, ready to be packaged.
public struct Article: Sendable, Equatable {
    /// Canonical URL; the article id is derived from it.
    public var url: String
    /// Publication, e.g. "The New York Times" or a Substack's name.
    public var source: String
    public var title: String
    public var author: String
    public var date: Date
    /// Cleaned block-level XHTML (the output of `HTMLCleaner`).
    public var bodyXHTML: String
    public var images: [ArticleImage] = []
    public var imageSources: [ArticleImageSource] = []
    public var language: String

    public init(url: String, source: String, title: String, author: String, date: Date, bodyXHTML: String, language: String = "en") {
        self.url = url
        self.source = source
        self.title = title
        self.author = author
        self.date = date
        self.bodyXHTML = bodyXHTML
        self.language = language
    }

    public var id: ArticleID { ArticleID(canonicalURL: url) }
}

/// Builds a single-chapter EPUB 3 that also carries an EPUB 2 NCX, so both old and new readers
/// find a table of contents. Text with optional monochrome PNG images. The output depends only on the article, never on the
/// clock, so packaging the same article twice gives the same bytes (and the same CRC).
public enum EpubBuilder {
    public static let mimetype = "application/epub+zip"

    /// Entry names, in archive order.
    public static let entryNames = [
        "mimetype", "META-INF/container.xml", "OEBPS/content.opf", "OEBPS/toc.ncx", "OEBPS/nav.xhtml", "OEBPS/article.xhtml",
    ]

    public enum Failure: Error { case invalidImage }
    public static func build(_ article: Article) throws -> Data {
        var paths = Set<String>()
        guard article.images.reduce(0, { $0 + $1.data.count }) <= 512 * 1024 else { throw Failure.invalidImage }
        for image in article.images {
            guard image.path.range(of: #"^images/[A-Za-z0-9_-]+\.png$"#, options: .regularExpression) != nil,
                  paths.insert(image.path).inserted, image.data.count > 33,
                  image.data.starts(with: [137,80,78,71,13,10,26,10]), image.data[24] == 1, image.data[25] == 0 else {
                throw Failure.invalidImage
            }
        }
        var zip = ZipWriter(modified: article.date)
        // The mimetype entry must come first, stored, with no extra field.
        try zip.add(name: "mimetype", contents: Data(mimetype.utf8))
        try zip.add(name: "META-INF/container.xml", contents: Data(containerXML.utf8))
        try zip.add(name: "OEBPS/content.opf", contents: Data(packageDocument(article).utf8))
        try zip.add(name: "OEBPS/toc.ncx", contents: Data(ncx(article).utf8))
        try zip.add(name: "OEBPS/nav.xhtml", contents: Data(nav(article).utf8))
        try zip.add(name: "OEBPS/article.xhtml", contents: Data(chapter(article).utf8))
        for image in article.images {
            try zip.add(name: "OEBPS/" + image.path, contents: image.data)
        }
        return try zip.finish()
    }

    static let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>

        """

    private static func displayTitle(_ article: Article) -> String {
        let title = SyncText.sanitizeField(article.title)
        return title.isEmpty ? "Untitled" : title
    }

    private static func languageTag(_ article: Article) -> String {
        let allowed = article.language.unicodeScalars.allSatisfy {
            ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) || ($0.value >= 48 && $0.value <= 57) || $0 == "-"
        }
        return (allowed && !article.language.isEmpty) ? article.language : "en"
    }

    static func packageDocument(_ article: Article) -> String {
        let e = HTMLCleaner.escape
        let author = SyncText.sanitizeField(article.author)
        let source = SyncText.sanitizeField(article.source)
        let stamp = ISODate.format(article.date)
        let identifier = article.url.isEmpty ? "urn:paperboy:\(article.id.hex)" : article.url
        var lines: [String] = []
        lines.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        lines.append("<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"bookid\" xml:lang=\"\(languageTag(article))\">")
        lines.append("  <metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\">")
        lines.append("    <dc:identifier id=\"bookid\">\(e(identifier))</dc:identifier>")
        lines.append("    <dc:title>\(e(displayTitle(article)))</dc:title>")
        if !author.isEmpty { lines.append("    <dc:creator>\(e(author))</dc:creator>") }
        lines.append("    <dc:language>\(languageTag(article))</dc:language>")
        if !source.isEmpty { lines.append("    <dc:publisher>\(e(source))</dc:publisher>") }
        lines.append("    <dc:date>\(stamp)</dc:date>")
        lines.append("    <meta property=\"dcterms:modified\">\(stamp)</meta>")
        lines.append("    <meta name=\"paperboy:id\" content=\"\(article.id.hex)\"/>")
        lines.append("  </metadata>")
        lines.append("  <manifest>")
        lines.append("    <item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>")
        lines.append("    <item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>")
        lines.append("    <item id=\"article\" href=\"article.xhtml\" media-type=\"application/xhtml+xml\"/>")
        for (index, image) in article.images.enumerated() {
            lines.append("    <item id=\"image\(index)\" href=\"\(e(image.path))\" media-type=\"image/png\"/>")
        }
        lines.append("  </manifest>")
        lines.append("  <spine toc=\"ncx\">")
        lines.append("    <itemref idref=\"article\"/>")
        lines.append("  </spine>")
        lines.append("</package>")
        return lines.joined(separator: "\n") + "\n"
    }

    static func ncx(_ article: Article) -> String {
        let e = HTMLCleaner.escape
        let identifier = article.url.isEmpty ? "urn:paperboy:\(article.id.hex)" : article.url
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
              <head>
                <meta name="dtb:uid" content="\(e(identifier))"/>
                <meta name="dtb:depth" content="1"/>
                <meta name="dtb:totalPageCount" content="0"/>
                <meta name="dtb:maxPageNumber" content="0"/>
              </head>
              <docTitle><text>\(e(displayTitle(article)))</text></docTitle>
              <navMap>
                <navPoint id="article" playOrder="1">
                  <navLabel><text>\(e(displayTitle(article)))</text></navLabel>
                  <content src="article.xhtml"/>
                </navPoint>
              </navMap>
            </ncx>

            """
    }

    static func nav(_ article: Article) -> String {
        let e = HTMLCleaner.escape
        let lang = languageTag(article)
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(lang)" lang="\(lang)">
            <head><title>\(e(displayTitle(article)))</title></head>
            <body>
            <nav epub:type="toc" id="toc">
            <ol>
            <li><a href="article.xhtml">\(e(displayTitle(article)))</a></li>
            </ol>
            </nav>
            </body>
            </html>

            """
    }

    /// "Author · Source · 15 November 2026", skipping whatever is missing.
    static func bylineText(_ article: Article) -> String {
        var parts: [String] = []
        let author = SyncText.sanitizeField(article.author)
        let source = SyncText.sanitizeField(article.source)
        if !author.isEmpty { parts.append(author) }
        if !source.isEmpty, source != author { parts.append(source) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        formatter.dateFormat = "d MMMM yyyy"
        parts.append(formatter.string(from: article.date))
        return parts.joined(separator: " \u{00B7} ")
    }

    static func chapter(_ article: Article) -> String {
        let e = HTMLCleaner.escape
        let lang = languageTag(article)
        let body = ArticleImageMarkup.resolving(article).trimmingCharacters(in: .whitespacesAndNewlines)
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="\(lang)" lang="\(lang)">
            <head><title>\(e(displayTitle(article)))</title></head>
            <body>
            <h1>\(e(displayTitle(article)))</h1>
            <p><em>\(e(bylineText(article)))</em></p>
            <hr/>
            \(body.isEmpty ? "<p>(This article has no text.)</p>" : body)
            </body>
            </html>

            """
    }
}

/// What can be read back out of an EPUB's package document.
public struct EpubMetadata: Sendable, Equatable {
    public var title: String?
    public var author: String?
    public var publisher: String?
    public var identifier: String?
    public var date: Date?

    public init(title: String? = nil, author: String? = nil, publisher: String? = nil, identifier: String? = nil, date: Date? = nil) {
        self.title = title
        self.author = author
        self.publisher = publisher
        self.identifier = identifier
        self.date = date
    }
}

public enum EpubInspector {
    /// Read title/creator/publisher/identifier/date from any EPUB (stored or deflated entries).
    public static func metadata(of epub: Data) throws -> EpubMetadata {
        let zip = try ZipReader(epub)
        let container = String(decoding: try zip.contents(named: "META-INF/container.xml"), as: UTF8.self)
        guard let opfPath = firstMatch(in: container, pattern: "full-path\\s*=\\s*[\"']([^\"']+)[\"']") else {
            throw ZipReader.ZipReadError.noSuchEntry("package document")
        }
        let opf = String(decoding: try zip.contents(named: opfPath), as: UTF8.self)
        func element(_ name: String) -> String? {
            guard let raw = firstMatch(in: opf, pattern: "<dc:\(name)\\b[^>]*>([\\s\\S]*?)</dc:\(name)>") else { return nil }
            let text = HTMLCleaner.plainText(raw)
            return text.isEmpty ? nil : text
        }
        var metadata = EpubMetadata()
        metadata.title = element("title")
        metadata.author = element("creator")
        metadata.publisher = element("publisher")
        metadata.identifier = element("identifier")
        metadata.date = element("date").flatMap(ISODate.parse)
        return metadata
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[captured])
    }
}
