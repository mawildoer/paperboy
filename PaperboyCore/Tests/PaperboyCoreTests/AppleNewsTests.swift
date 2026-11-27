import Foundation
import Testing
@testable import PaperboyCore

private final class NewsPageProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let status = url.path == "/Aredirect" ? 302 : (url.path == "/Agone" ? 410 : 200)
        let headers = status == 302 ? ["Location": "https://publisher.example/article"] : ["Content-Type": "text/html"]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        let footer = #"<a href="https://www.apple.com/news/">Learn more about Apple News</a>"#
        let link = #"<a href="https://publisher.example/story?one=1&amp;two=2"><span class="click-here">Click here</span><span class="tap-here">Tap here</span></a>"#
        client?.urlProtocol(self, didLoad: Data(((url.path == "/Astory" ? link : "") + footer).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite struct AppleNewsTests {
    @Test func resolvesTheWebEditionOrReportsThatItIsUnavailable() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NewsPageProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        #expect(try await AppleNews.resolve(URL(string: "https://apple.news/Astory")!, session: session).absoluteString == "https://publisher.example/story?one=1&two=2")
        #expect(try await AppleNews.resolve(URL(string: "https://apple.news/Aredirect")!, session: session).host == "publisher.example")
        for path in ["Aunavailable", "Agone"] {
            await #expect(throws: AppleNews.Failure.noWebEdition) { try await AppleNews.resolve(URL(string: "https://apple.news/" + path)!, session: session) }
        }
    }

    @Test func rejectsAppleLandingPagesAndUsesPublisherCanonical() {
        let base = URL(string: "https://apple.news/A123")!
        let page = #"<link rel="canonical" href="/A123"><meta property="og:url" content="https://apple.news/A123"><a href="https://www.apple.com/privacy/">Privacy</a><a href="https://elsewhere.example/">Advertiser</a>"#
        #expect(AppleNews.publisherURL(in: page, base: base) == nil)
        #expect(AppleNews.publisherURL(in: page + #"<link href="https://news.example/story" rel="canonical">"#, base: base)?.absoluteString == "https://news.example/story")
        #expect(!AppleNews.isNewsURL(URL(string: "https://apple.news.example/A123")!))
    }
}
