import Foundation
import Testing
@testable import PaperboyCore

@Suite struct SharedPublisherTests {
    private func identify(_ address: String, html: String? = nil, favourites: [String] = []) -> SharedPublisher? {
        SharedPublisher.identify(URL(string: address)!, sharedHTML: html, substackPublications: favourites)
    }

    @Test func publisherAndShortLinks() {
        let shares: [(String, SharedPublisher)] = [
            ("https://WWW.Economist.COM:443/interactive/a-story?giftId=x", .economist),
            ("https://economist.com/node/123", .economist),
            ("https://econ.st/a12", .economist),
            ("https://www.nytimes.com/2026/11/11/world/story.html", .nyt),
            ("https://nytimes.com/story", .nyt),
            ("https://nyti.ms/x", .nyt),
            ("https://medium.com/@writer/a-story-abcdef123456", .medium),
            ("https://news.medium.com/story", .medium),
            ("https://writer.substack.com/p/an-essay", .substack),
            ("https://open.substack.com/pub/writer/p/an-essay?r=abc", .substack),
            ("https://substack.com/home/post/p-123", .substack),
            ("https://substack.com/app-link/post?publication_id=12&post_id=34", .substack),
        ]
        for (address, publisher) in shares {
            #expect(identify(address) == publisher)
        }
    }

    @Test func unsafeAuthoritiesNeverUseFavouritesOrMetadata() {
        let html = #"<meta name="generator" content="Substack">"#
        for address in ["http://medium.com/p/story", "ftp://substack.com/p/story", "/p/story",
                        "https://name:password@nytimes.com/story", "https://@medium.com/p/story",
                        "https://econ.st@news.example/x", "https://substack.com:8443/p/story",
                        "https://%6Dedium.com/x", "https://x%2Esubstack.com/x",
                        "https://bad..substack.com/p/x", "https://.medium.com/x",
                        "https://-bad.medium.com/x", "https://econ.st./x"] {
            #expect(identify(address, html: html, favourites: ["news.example"]) == nil)
        }
    }

    @Test func noImpliedPublisherFromTextPathOrSuffix() {
        let html = """
            <html><head><title>Medium on Substack</title>
            <meta property="og:site_name" content="Medium"></head><body>
            <a href="https://substack.com/p/welcome">Read my Substack</a></body></html>
            """
        for host in ["example.org", "noteconomist.com", "econ.st.example", "fakenytimes.com", "nyti.ms.example",
                     "notmedium.com", "medium.com.example", "notsubstack.com", "substack.com.example"] {
            #expect(identify("https://\(host)/p/story-abcdef123456?next=https://medium.com", html: html) == nil)
        }
    }

    @Test func favouritesAcceptHostsAndPublicationURLsWithExactBoundaries() {
        let favourites = ["  https://WWW.Press.example:443/p/story?ref=abc  ", "news.other.example/feed", "writer"]
        for host in ["press.example", "www.press.example", "news.other.example", "writer.substack.com"] {
            #expect(identify("https://\(host)/p/second", favourites: favourites) == .substack)
        }
        for host in ["press.example.attacker.test", "badpress.example", "other.example", "staff.press.example", "writer.org"] {
            #expect(identify("https://\(host)/p/second", favourites: favourites) == nil)
        }
        let bad = ["http://press.example", "https://trusted.test@press.example", "press.example:8080/p/one", "%70ress.example"]
        #expect(identify("https://press.example/p/second", favourites: bad) == nil)
        #expect(identify("https://medium.com/p/story", favourites: ["medium.com"]) == .medium)
    }

    @Test func preservedPlatformMetadataRoutesOnlyThatShare() {
        let hints: [(String, SharedPublisher)] = [
            (#"<meta content="Medium" property="al:ios:app_name">"#, .medium),
            (#"<meta property="al:android:url" content="medium://p/abcdef123456">"#, .medium),
            (#"<meta name="twitter:app:id:iphone" content="828256236">"#, .medium),
            (#"<link rel="canonical" href="https://press.medium.com/some-story-abcdef123456">"#, .medium),
            (#"<meta CONTENT="Substack" NAME="generator">"#, .substack),
            (#"<meta name="apple-itunes-app" content="app-id=1581650857, app-argument=x">"#, .substack),
            (#"<meta property="al:ios:url" content="substack://post?post_id=42">"#, .substack),
            (#"<meta property="al:ios:url" content="https://open.substack.com/pub/writer/p/a-story">"#, .substack),
            (#"<link type="application/rss+xml" href="//writer.substack.com/feed" rel="alternate">"#, .substack),
        ]
        for (html, publisher) in hints {
            #expect(identify("https://press.example/story", html: html) == publisher)
        }
        #expect(identify("https://press.example/story") == nil)
        #expect(identify("https://press.example/p/another-story") == nil)
    }

    @Test func scansPastOtherHeadElementsAndIgnoresBodyMetadata() {
        let before = """
            <!doctype html><html><head>
            <script>const markup = '<meta name="generator" content="Medium">'; /*\(String(repeating: "x", count: 210_000))*/</script>
            <style>body { color: black }</style><title>Daily press</title>
            <object></object><meta charset="UTF-8">
            """
        let after = #"</head><body><meta name="generator" content="Medium"></body></html>"#
        #expect(identify("https://news.example/p/test", html: before + after) == nil)
        let canonical = #"<link rel="canonical" href="https://press.substack.com/p/test">"#
        #expect(identify("https://news.example/p/test", html: before + canonical + after) == .substack)
    }

    @Test func ignoresUnrelatedAndAmbiguousMetadata() {
        let medium = #"<meta name="generator" content="Medium">"#
        for html in [
            "<!-- \(medium) -->", "<template>\(medium)</template>", "<title>\(medium)</title>",
            "<html><body>\(medium)</body></html>", "<article>\(medium)</article>",
            #"<meta property="og:description" content="A Medium story">"#,
            #"<meta name="generator" content="My Substack reader">"#,
            #"<meta name="apple-itunes-app" content="app-id=15816508570">"#,
            #"<link rel="alternate" type="application/rss+xml" href="/feed">"#,
            #"<link rel="stylesheet" href="https://writer.substack.com/style.css">"#,
            #"<link rel="canonical" href="https://writer.substack.com.example/p/x">"#,
            #"<meta property="al:ios:url" content="https://another.example/medium.com">"#,
            #"<meta property="al:ios:url" content="https://user@medium.com/p/x">"#,
            #"<meta property="al:ios:url" content="https://substack.com:8443/p/story">"#,
            #"<meta property="al:ios:url" content="medium://user@p/abcdef123456">"#,
            medium + #"<meta property="al:android:app_name" content="Substack">"#,
        ] {
            #expect(identify("https://news.example/p/test", html: html) == nil)
        }
    }

    @Test func explicitPDFsAlwaysUseThePDFImporter() {
        for host in ["www.economist.com", "nyti.ms", "medium.com", "open.substack.com", "configured.example", "unknown.example"] {
            #expect(identify("https://\(host)/report%2EPDF?download=1#page=2",
                             html: #"<meta name="generator" content="Substack">"#,
                             favourites: ["configured.example"]) == nil)
        }
        #expect(identify("https://nytimes.com/story?file=report.pdf") == .nyt)
    }
}
