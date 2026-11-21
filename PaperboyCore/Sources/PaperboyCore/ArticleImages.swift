import Foundation

public struct ArticleImage: Sendable, Equatable {
    public let path: String
    public let data: Data
    public let width: Int
    public let height: Int
    public init(path: String, data: Data, width: Int, height: Int) {
        self.path = path
        self.data = data
        self.width = width
        self.height = height
    }
}

public struct ArticleImageSource: Sendable, Equatable {
    public let url: URL
    public let path: String
    public let alt: String
    public let likelyChart: Bool

    static func rawSource(_ attributes: [String: String]) -> String {
        for key in ["data-src", "data-lazy-src"] {
            if let value = attributes[key], !value.isEmpty { return value }
        }
        let candidates = (attributes["data-srcset"] ?? attributes["srcset"] ?? "").split(separator: ",").compactMap {
            value -> (String, Double)? in
            let fields = value.split(whereSeparator: \.isWhitespace)
            guard let url = fields.first else { return nil }
            let size = fields.count > 1 ? Double(fields[1].dropLast()) ?? 1 : 1
            return (String(url), size)
        }
        if let largest = candidates.max(by: { $0.1 < $1.1 }) { return largest.0 }
        return attributes["src"] ?? ""
    }

    init?(raw: String, attributes: [String: String], baseURL: String, index: Int) {
        guard !raw.isEmpty, raw.utf8.count <= 6_000_000,
            let url = URL(string: raw, relativeTo: URL(string: baseURL))?.absoluteURL,
            ["https", "http", "data"].contains(url.scheme?.lowercased() ?? "")
        else { return nil }
        if let w = attributes["width"].flatMap(Int.init), let h = attributes["height"].flatMap(Int.init), w < 40 || h < 30 { return nil }
        let description = ((attributes["alt"] ?? "") + " " + raw.prefix(1000)).lowercased()
        if ["avatar", "tracking-pixel", "spacer.gif", "emoji"].contains(where: description.contains) { return nil }
        self.url = url
        self.path = "images/image-\(index).png"
        self.alt = attributes["alt"] ?? ""
        self.likelyChart = ["chart", "plot", "graph", "figure", "diagram", "histogram", "scatter", "table"].contains(
            where: description.contains)
    }
}

/// Removes unresolved references even for callers that package without running the downloader.
enum ArticleImageMarkup {
    static func resolving(_ article: Article) -> String {
        var body = article.bodyXHTML
        for source in article.imageSources where !article.images.contains(where: { $0.path == source.path }) {
            let pattern = #"<img\b[^>]*src="\#(NSRegularExpression.escapedPattern(for: source.path))"[^>]*/>"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: body, range: NSRange(body.startIndex..., in: body)).reversed() {
                guard let range = Range(match.range, in: body) else { continue }
                body.replaceSubrange(range, with: source.alt.isEmpty ? "" : "[Image: \(HTMLCleaner.escape(source.alt))]")
            }
        }
        return body
    }
}
