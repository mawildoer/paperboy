import Foundation
import Testing
import WebKit
@testable import PaperboyCore

@MainActor
@Suite struct SubstackSharedStoryTests {
    private let canonical = "https://publication.example/p/river-count"
    private let ending = "Counts from the final station confirmed the spring recovery."

    private func post(extraHead: String = "", inside: String = "", after: String = "") -> String {
        let paragraph = "<p>Each spring the team measures river levels and counts every species of returning fish. The records cover twenty seasons and every station in the valley.</p>"
        return """
            <head><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
            <title>River count</title><meta name="author" content="Sam Writer">
            <link rel="alternate" type="application/rss+xml" title="River Reports" href="/feed">
            \(extraHead)</head><body><nav>Sign in · Subscribe</nav><article class="newsletter-post">
            <header><h1>The river count</h1><time datetime="2025-01-02T12:00:00Z">Jan 2</time></header>
            <div class="available-content"><div class="body markup">\(String(repeating: paragraph, count: 4))
            \(inside)<p>\(ending)</p></div></div></article>\(after)</body>
            """
    }

    /// Load offline markup at the URL WebKit would see after the publisher's last redirect.
    private func snapshot(_ html: String, landedAt url: String) async throws -> WebPublicationSource.Snapshot {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        defer { web.stopLoading() }
        web.loadHTMLString(html, baseURL: URL(string: url))
        let deadline = ContinuousClock.now + .seconds(10)
        while web.isLoading || web.url == nil {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(20))
        }
        return try await SubstackSharedStory.snapshot(in: web)
    }

    @Test func mobileGiftUsesOriginalLinkAndReadsOnlyTheLandedPost() async throws {
        let share = URL(string: "https://open.substack.com/pub/river/p/river-count?token=gift%2B123&r=abc")!
        let hidden = "PRIVATE_CONTINUATION"
        let html = post(inside: """
            <figure><img src="/chart.png"><figcaption>Spring observations</figcaption></figure>
            <span style="display:none">\(hidden)</span><template><p>\(hidden)</p></template>
            <span style="color:transparent">\(hidden)</span><span style="position:absolute;left:-9999px">\(hidden)</span>
            <script type="application/ld+json">{"articleBody":"\(hidden)"}</script>
            """, after: "<div class='paywall' hidden>Subscribe to continue reading</div><div role='dialog'>Keyboard shortcuts</div>")
        var navigations = [String]()
        let article = try await SubstackSharedStory.fetch(share, signInToPublication: { _, _ in
            Issue.record("A readable gift should not start a publication sign-in")
            return false
        }) { url, _, capture in
            #expect(capture == .substackStory)
            navigations.append(url)
            return try await snapshot(html, landedAt: canonical + "?token=redeemed#part")
        }
        #expect(navigations == [share.absoluteString])
        #expect(article.url == canonical && article.id == ArticleID(canonicalURL: canonical))
        #expect(article.title == "The river count" && article.source == "River Reports" && article.author == "Sam Writer")
        #expect(article.date == ISODate.parse("2025-01-02T12:00:00Z"))
        #expect(article.bodyXHTML.contains(ending) && article.bodyXHTML.contains("Spring observations"))
        #expect(!article.bodyXHTML.contains(hidden) && !article.bodyXHTML.contains("Sign in"))
        #expect(article.imageSources.first?.url.absoluteString == "https://publication.example/chart.png")
    }

    @Test func renderedMobilePostUsesItsDeclaredPublicationURL() async throws {
        let html = post(extraHead: "<link rel='canonical' href='\(canonical)?gift=opaque#p'>")
        let page = try await snapshot(html, landedAt: "https://substack.com/home/post/p-12345")
        #expect(page.url.absoluteString == canonical)
        #expect(!page.html.contains("opaque"))
    }

    private let firstPartyWall = """
        <div class="paywall"><h2>This post is for paid subscribers</h2>
        <a href="https://substack.com/sign-in?for_pub=river&amp;redirect=https%3A%2F%2Fother.example">
        Already a paid subscriber? Sign in</a></div>
        """

    @Test func customPublicationSessionRetriesOriginalGiftOnce() async throws {
        let share = URL(string: "https://substack.com/home/post/p-12345?gift=token%2Bwith%2Bescapes")!
        var navigations = [String]()
        var signIns = [String]()
        let article = try await SubstackSharedStory.fetch(share, signInToPublication: { host, name in
            signIns.append("\(name) at \(host)")
            return true
        }) { address, _, capture in
            #expect(capture == .substackStory)
            navigations.append(address)
            return try await snapshot(post(after: navigations.count == 1 ? firstPartyWall : ""), landedAt: canonical)
        }
        #expect(signIns == ["river at publication.example"])
        #expect(navigations == [share.absoluteString, share.absoluteString])
        #expect(article.url == canonical && article.bodyXHTML.contains(ending))
    }

    @Test func realWallAndChallengeStayClosedAfterSignIn() async throws {
        let share = URL(string: canonical)!
        for (wall, established, expectedSignIns) in [
            (firstPartyWall, true, 1),
            (firstPartyWall, false, 1),
            (firstPartyWall + "<h1>Verify you are human</h1>", true, 0),
            (firstPartyWall.replacingOccurrences(of: "substack.com/sign-in", with: "substack.com.other.example/sign-in"), true, 0),
        ] {
            var signIns = 0
            var navigations = 0
            await #expect(throws: SubstackShareError.unreadable) {
                _ = try await SubstackSharedStory.fetch(share, signInToPublication: { _, _ in
                    signIns += 1
                    return established
                }) { _, _, _ in
                    navigations += 1
                    return try await snapshot(post(after: wall), landedAt: canonical)
                }
            }
            #expect(signIns == expectedSignIns)
            #expect(navigations == (established && expectedSignIns == 1 ? 2 : 1))
        }
    }

    @Test func refusesTeasersSignInChallengesAndClippedBodies() async throws {
        let variants = [
            post(after: "<aside data-testid='paywall'>Choose a plan</aside>"),
            post(after: "<div><strong>This post is for</strong> paid subscribers</div>"),
            post(after: "<form>Sign in to continue reading</form>"),
            post(after: "<h1>Verify you are human</h1>"),
            post(after: "<div role='dialog' aria-modal='true'>Sign in</div>"),
            post(inside: "<div hidden><p>Withheld ending</p></div>"),
            post(extraHead: "<style>.available-content { height: 3em; overflow: hidden }</style>"),
            post(extraHead: "<style>.body { filter: blur(4px) }</style>"),
        ]
        for html in variants {
            await #expect(throws: SubstackShareError.unreadable) { _ = try await snapshot(html, landedAt: canonical) }
        }
        for url in ["https://substack.com/sign-in", "https://publication.example/subscribe",
                    "https://substack.com.evil.example/home/post/p-12345"] {
            await #expect(throws: SubstackShareError.unreadable) {
                _ = try await snapshot(post(extraHead: "<link rel='canonical' href='\(canonical)'>"), landedAt: url)
            }
        }
    }

    @Test func genericRedirectAndUnrelatedCanonicalCannotSupplyPostIdentity() async throws {
        let foreign = "https://unrelated.example/p/some-other-post"
        let html = post(extraHead: "<link rel='canonical' href='\(foreign)'>")
        let page = try await snapshot(html, landedAt: canonical)
        #expect(page.url.absoluteString == canonical)
        await #expect(throws: SubstackShareError.unreadable) {
            _ = try await snapshot("<article><h1>Generic page</h1><p>Foreign text</p></article>", landedAt: foreign)
        }
    }
}
