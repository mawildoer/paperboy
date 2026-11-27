import Foundation

/// Apple News shares a story landing page. Resolve its advertised web edition before importing.
public enum AppleNews {
    public enum Failure: LocalizedError {
        case noWebEdition
        public var errorDescription: String? {
            "Apple News didn’t provide a publisher link for this story. If you can open it on the publisher’s website, share that page from Safari."
        }
    }

    public static func isNewsURL(_ url: URL) -> Bool {
        ["apple.news", "www.apple.news", "news.apple.com"].contains(url.host?.lowercased())
    }

    private static func publisher(_ raw: String?, relativeTo base: URL) -> URL? {
        guard let raw, let url = URL(string: raw, relativeTo: base)?.absoluteURL,
              url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              url.user == nil, url.password == nil, !isNewsURL(url),
              !host.hasSuffix(".apple.news") else { return nil }
        if host == "apple.com" || host.hasSuffix(".apple.com") {
            guard host == "www.apple.com", url.path.hasPrefix("/newsroom/") else { return nil }
        }
        return url
    }

    static func publisherURL(in html: String, base: URL) -> URL? {
        var canonical: URL?, fallback: URL?
        func visit(_ node: HTMLNode) {
            let attrs = node.attributes
            if node.name == "link", (attrs["rel"] ?? "").lowercased().split(whereSeparator: \.isWhitespace).contains("canonical") {
                canonical = canonical ?? publisher(attrs["href"], relativeTo: base)
            } else if node.name == "a", node.children.contains(where: { child in
                guard case .element(let span) = child else { return false }
                let classes = (span.attributes["class"] ?? "").split(whereSeparator: \.isWhitespace)
                return classes.contains("click-here") || classes.contains("tap-here")
            }) {
                fallback = fallback ?? publisher(attrs["href"], relativeTo: base)
            } else if node.name == "meta", attrs["property"]?.lowercased() == "og:url" {
                fallback = fallback ?? publisher(attrs["content"], relativeTo: base)
            }
            for case .element(let child) in node.children { visit(child) }
        }
        visit(HTMLTreeBuilder.build(html, maxDepth: 32))
        return canonical ?? fallback
    }

    public static func resolve(_ url: URL, session: URLSession = .shared) async throws -> URL {
        guard isNewsURL(url), url.scheme?.lowercased() == "https", url.user == nil, url.password == nil else { throw Failure.noWebEdition }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.httpShouldHandleCookies = false
        // A publisher redirect should go through the same signed-in import path as a direct share.
        let (bytes, response) = try await session.bytes(for: request, delegate: StopAtPublisher())
        guard let http = response as? HTTPURLResponse, let final = http.url else { throw URLError(.badServerResponse) }
        if (300..<400).contains(http.statusCode),
           let target = publisher(http.value(forHTTPHeaderField: "Location"), relativeTo: final) { return target }
        if [404, 410].contains(http.statusCode) { throw Failure.noWebEdition }
        guard http.statusCode == 200, isNewsURL(final) else { throw URLError(.badServerResponse) }
        let limit = 512 * 1024
        guard http.expectedContentLength <= limit else { throw URLError(.dataLengthExceedsMaximum) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        guard let target = publisherURL(in: String(decoding: data, as: UTF8.self), base: final) else { throw Failure.noWebEdition }
        return target
    }

    private final class StopAtPublisher: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            guard let url = request.url, AppleNews.isNewsURL(url), url.scheme == "https", url.user == nil, url.password == nil else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }
}
