import Foundation
import WebKit

public enum SubstackShareError: LocalizedError {
    case unreadable

    public var errorDescription: String? {
        "Paperboy couldn’t read the full Substack post. Check your sign-in and access on the publication’s website."
    }
}

private struct SubstackPublicationSignIn: Error {
    let host: String
    let subdomain: String
}

@MainActor
public enum SubstackSharedStory {
    public static func fetch(_ url: URL, signInToPublication: (String, String) async throws -> Bool,
                             loadPage: WebPublicationSource.LoadPage) async throws -> Article {
        guard url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else {
            throw URLError(.badURL)
        }
        try Task.checkCancellation()
        // WebKit follows the publisher's redirects and scopes cookies to each request.
        // Keep the original gift query for navigation. The snapshot supplies the post identity.
        func load() async throws -> WebPublicationSource.Snapshot {
            try Task.checkCancellation()
            return try await loadPage(url.absoluteString, 25, .substackStory)
        }
        let page: WebPublicationSource.Snapshot
        do {
            page = try await load()
        } catch let publication as SubstackPublicationSignIn {
            guard try await signInToPublication(publication.host, publication.subdomain) else {
                throw SubstackShareError.unreadable
            }
            do { page = try await load() }
            catch is SubstackPublicationSignIn { throw SubstackShareError.unreadable }
        }
        try Task.checkCancellation()
        return try PageExtractor.article(pageHTML: page.html, url: page.url.absoluteString, useStructuredNYT: false)
    }

    public static func snapshot(in web: WKWebView) async throws -> WebPublicationSource.Snapshot {
        guard let resource = Bundle.module.url(forResource: "SubstackStory", withExtension: "js") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let script = try String(contentsOf: resource, encoding: .utf8)
        let value = try await web.callAsyncJavaScript(script + "\nreturn substackStory(document);",
            arguments: [:], in: nil, contentWorld: .defaultClient)
        guard let result = value as? [String: String] else { throw SubstackShareError.unreadable }
        if let host = result["host"], let subdomain = result["for_pub"] {
            throw SubstackPublicationSignIn(host: host, subdomain: subdomain)
        }
        guard let html = result["html"],
              let address = result["url"], let canonical = URL(string: address) else {
            throw SubstackShareError.unreadable
        }
        return .init(url: canonical, html: html)
    }
}
