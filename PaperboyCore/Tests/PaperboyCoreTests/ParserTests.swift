import Foundation
import Testing

@testable import PaperboyCore

@Suite struct JSONValueTests {
    @Test func parsesOrdinaryJSON() throws {
        let value = try JSONValue.parse(#" {"a": [1, -2.5e2, true, false, null], "b": {"c": "d\n\u00e9\ud83d\ude00\/"}, "e": ""} "#)
        #expect(value["a"]?.arrayValue == [.number(1), .number(-250), .bool(true), .bool(false), .null])
        #expect(value.at("b", "c")?.stringValue == "d\né😀/")
        #expect(value["e"]?.stringValue == "")
        #expect(value["missing"] == nil)
        #expect(value.objectValue?.keys == ["a", "b", "e"])
    }

    @Test func keepsKeyOrder() throws {
        let value = try JSONValue.parse(#"{"z": 1, "a": 2, "m": 3, "a": 4}"#)
        #expect(value.objectValue?.keys == ["z", "a", "m"])
        #expect(value["a"]?.numberValue == 4)
    }

    @Test func lenientAboutJavaScript() throws {
        let value = try JSONValue.parse("{\"a\": undefined, \"b\": [undefined, 1,], \"c\": \"tab\there\",} trailing garbage;")
        #expect(value.objectValue?["a"] == .null)
        #expect(value["a"] == nil)
        #expect(value["b"]?.arrayValue == [.null, .number(1)])
        #expect(value["c"]?.stringValue == "tab\there")
    }

    @Test func rejectsBrokenInput() {
        for text in ["", "{", "{\"a\"}", "[1, 2", "\"unterminated", "{\"a\": tru}", "nope", "{\"a\": 1 \"b\": 2}", "\"bad \\u12G4\""] {
            #expect(throws: JSONParseError.self, "\(text)") { try JSONValue.parse(text) }
        }
        let deep = String(repeating: "[", count: 5000)
        #expect(throws: JSONParseError.tooDeep) { try JSONValue.parse(deep) }
    }

    @Test func loneSurrogatesBecomeReplacementCharacters() throws {
        #expect(try JSONValue.parse(#""a\ud800b""#).stringValue == "a\u{FFFD}b")
        #expect(try JSONValue.parse(#""a\udc00b""#).stringValue == "a\u{FFFD}b")
    }

    @Test func isoDates() {
        #expect(ISODate.parse("2026-11-15T10:00:11.000Z") == Date(timeIntervalSince1970: 1_794_736_811))
        #expect(ISODate.parse("2026-11-15T10:00:11Z") == Date(timeIntervalSince1970: 1_794_736_811))
        #expect(ISODate.parse("2026-11-15T05:00:11-05:00") == Date(timeIntervalSince1970: 1_794_736_811))
        #expect(ISODate.parse("yesterday") == nil)
        #expect(ISODate.format(Date(timeIntervalSince1970: 1_794_736_811)) == "2026-11-15T10:00:11Z")
    }
}

@Suite struct SubstackParserTests {
    @Test func decodesAPost() throws {
        let post = try SubstackParser.parsePost(json: Data(Fixtures.substackPostJSON.utf8))
        #expect(post.title == "Hello & welcome")
        #expect(post.subtitle == "A subtitle with <angle> brackets")
        #expect(post.canonicalURL == "https://example.substack.com/p/hello")
        #expect(post.slug == "hello")
        #expect(post.postDate == ISODate.parse("2026-11-14T15:30:00Z"))
        #expect(post.authors == ["Jane Writer", "Sam Coauthor"])
        #expect(post.audience == "only_paid")
        #expect(post.publicationName == "The Example Letter")
        #expect(post.host == "example.substack.com")
        #expect(post.bodyHTML == Fixtures.substackBodyHTML)
    }

    @Test func buildsACleanArticle() throws {
        let post = try SubstackParser.parsePost(json: Data(Fixtures.substackPostJSON.utf8))
        let article = try SubstackParser.article(from: post)
        #expect(article.url == "https://example.substack.com/p/hello")
        #expect(article.id == ArticleID(canonicalURL: "https://example.substack.com/p/hello"))
        #expect(article.source == "The Example Letter")
        #expect(article.author == "Jane Writer, Sam Coauthor")
        #expect(article.title == "Hello & welcome")
        #expect(article.date == ISODate.parse("2026-11-14T15:30:00Z"))
        #expect(article.bodyXHTML.hasPrefix("<p><em>A subtitle with &lt;angle&gt; brackets</em></p>\n"))
        expectWellFormedFragment(article.bodyXHTML)
        #expect(elementNames(in: article.bodyXHTML).isSubset(of: allowedElements))
        // And it packages.
        let zip = try ZipReader(try EpubBuilder.build(article))
        expectWellFormed(String(decoding: try zip.contents(named: "OEBPS/article.xhtml"), as: UTF8.self))
    }

    @Test func toleratesMissingFieldsAndWrappers() throws {
        let minimal = try SubstackParser.parsePost(json: Data(#"{"canonical_url": "https://x.substack.com/p/y"}"#.utf8))
        #expect(minimal.title == "")
        #expect(minimal.subtitle == nil)
        #expect(minimal.authors.isEmpty)
        #expect(minimal.bodyHTML == nil)
        #expect(minimal.postDate == nil)
        #expect(throws: SubstackError.noBody(audience: nil)) { try SubstackParser.article(from: minimal) }

        let wrapped = try SubstackParser.parsePost(
            json: Data(#"{"post": {"canonical_url": "https://x.substack.com/p/y", "title": 5, "subtitle": "", "publishedBylines": null, "body_html": "<p>hi</p>", "audience": "everyone", "post_date": "garbage"}}"#.utf8))
        #expect(wrapped.title == "")
        #expect(wrapped.subtitle == nil)
        #expect(wrapped.bodyHTML == "<p>hi</p>")
        #expect(wrapped.postDate == nil)
        let article = try SubstackParser.article(from: wrapped, fetchedAt: Date(timeIntervalSince1970: 100))
        #expect(article.title == "Untitled")
        #expect(article.source == "x.substack.com")
        #expect(article.date == Date(timeIntervalSince1970: 100))
        #expect(article.bodyXHTML == "<p>hi</p>\n")
    }

    @Test func reportsNonPostsAndNonJSON() {
        #expect(throws: SubstackError.notAPost) { try SubstackParser.parsePost(json: Data(#"{"error": "Not found"}"#.utf8)) }
        #expect(throws: SubstackError.notAPost) { try SubstackParser.parsePost(json: Data("[1,2]".utf8)) }
        #expect(throws: SubstackError.self) { try SubstackParser.parsePost(json: Data("<html>Sign in</html>".utf8)) }
        #expect(throws: SubstackError.self) { try SubstackParser.parseList(json: Data("<html>".utf8)) }
    }

    @Test func decodesTheArchive() throws {
        let refs = try SubstackParser.parseList(json: Data(Fixtures.substackArchiveJSON.utf8))
        #expect(refs.map(\.slug) == ["newest-post", "a-podcast", "hello"])
        #expect(refs[0].title == "Newest post")
        #expect(refs[0].canonicalURL == "https://example.substack.com/p/newest-post")
        #expect(refs[0].postDate == ISODate.parse("2026-11-15T09:00:00Z"))
        #expect(refs[0].audience == "only_paid")
        #expect(refs[1].type == "podcast")
        #expect(refs[0].host == "example.substack.com")
    }

    @Test func decodesTheInbox() throws {
        let data = Data(Fixtures.substackInboxJSON.utf8)
        let refs = try SubstackParser.parseList(json: data)
        #expect(refs.map(\.canonicalURL) == ["https://a.substack.com/p/from-a", "https://www.custom-domain.example/p/from-b"])
        #expect(refs[1].title == "From publication B")
        #expect(refs[1].postDate == ISODate.parse("2026-11-15T07:00:00Z"))
        #expect(try SubstackParser.parsePublicationHosts(json: data) == ["a.substack.com", "www.custom-domain.example"])
        #expect(try SubstackParser.parseList(json: Data("{}".utf8)).isEmpty)
        #expect(try SubstackParser.parseList(json: Data("[]".utf8)).isEmpty)
    }

    @Test func endpoints() {
        #expect(SubstackEndpoints.post(host: "example.substack.com", slug: "hello")?.absoluteString == "https://example.substack.com/api/v1/posts/hello")
        #expect(
            SubstackEndpoints.post(forCanonicalURL: "https://example.substack.com/p/hello-world?utm=1")?.absoluteString
                == "https://example.substack.com/api/v1/posts/hello-world")
        #expect(SubstackEndpoints.post(forCanonicalURL: "https://example.substack.com/about") == nil)
        #expect(
            SubstackEndpoints.archive(host: "example.substack.com", limit: 5)?.absoluteString
                == "https://example.substack.com/api/v1/archive?sort=new&limit=5")
        #expect(SubstackEndpoints.inbox(limit: 50)?.query == "inboxType=inbox&limit=20")
        #expect(SubstackEndpoints.inbox(limit: 20)?.host == "substack.com")
    }
}

@Suite struct NYTParserTests {
    static let expectedBody = """
        <p><i>A one-line summary.</i></p>
        <p>Plain text, then <strong>bold</strong> and <strong><em>bold italic link</em></strong> &amp; a &lt;tag&gt; that must be escaped.</p>
        <h2>A subheading</h2>
        <p><em>People standing somewhere. Jane Doe for The New York Times</em></p>
        <blockquote>
        <p><em>Quoted words.</em></p>
        </blockquote>
        <ul>
        <li>
        <p>Item one</p>
        </li>
        <li>
        <p>Item two<br/>second line</p>
        </li>
        </ul>
        <hr/>
        <h3>Smaller heading</h3>
        <p>A reporter contributed from somewhere.</p>
        <p>Text inside an unknown block survives.</p>
        <p>The word undefined inside a string, and &quot;undefined&quot; in quotes, stay.</p>

        """

    @Test func parsesTheScript() throws {
        let article = try NYTParser.parse(preloadedData: Fixtures.nytPreloadedScript)
        #expect(article.headline == "An Example Story")
        #expect(article.byline == "Jane Reporter and John Correspondent")
        #expect(article.firstPublished == Date(timeIntervalSince1970: 1_794_736_811))
        #expect(article.url == "https://www.nytimes.com/2026/11/15/world/example-story.html")
        #expect(article.summary == "A one-line summary.")
        #expect(article.bodyXHTML == Self.expectedBody)
        expectWellFormedFragment(article.bodyXHTML)
        #expect(elementNames(in: article.bodyXHTML).isSubset(of: allowedElements))
    }

    @Test func parsesTheWholePage() throws {
        let article = try NYTParser.parse(pageHTML: Fixtures.nytPage)
        #expect(article.headline == "An Example Story")
        #expect(article.bodyXHTML == Self.expectedBody)
    }

    @Test func parsesStringifiedJSON() throws {
        // What JSON.stringify(window.__preloadedData) returns: no prefix, no undefined.
        let literal = NYTParser.sanitizeJavaScriptLiteral(Fixtures.nytPreloadedScript)
        let start = try #require(literal.firstIndex(of: "{"))
        let end = try #require(literal.lastIndex(of: "}"))
        let json = String(literal[start...end])
        _ = try JSONSerialization.jsonObject(with: Data(json.utf8))  // it really is strict JSON now
        #expect(try NYTParser.parse(preloadedData: json).bodyXHTML == Self.expectedBody)
    }

    @Test func undefinedIsReplacedOnlyOutsideStrings() {
        let input = #"{"a":undefined,"b":[undefined,undefined],"c":"undefined \" undefined","undefined":1,"d":xundefined,"e":undefinedy, "f": undefined}"#
        let expected = #"{"a":null,"b":[null,null],"c":"undefined \" undefined","undefined":1,"d":xundefined,"e":undefinedy, "f": null}"#
        #expect(NYTParser.sanitizeJavaScriptLiteral(input) == expected)
        #expect(NYTParser.sanitizeJavaScriptLiteral("undefined") == "null")
        #expect(NYTParser.sanitizeJavaScriptLiteral("") == "")
    }

    @Test func findsTheArticleUnderLoaderData() throws {
        let article = try NYTParser.parse(preloadedData: Fixtures.nytLoaderDataScript)
        #expect(article.headline == "An Example Story")
        #expect(article.bodyXHTML == Self.expectedBody)
    }

    @Test func findsTheArticleInAnUnexpectedPlace() throws {
        let script = "window.__preloadedData = {\"initialData\": {}, \"loaderData\": {\"routes/article\": {\"payload\": [{\"article\": \(Fixtures.nytArticleObject())}]}}};"
        let article = try NYTParser.parse(preloadedData: script)
        #expect(article.headline == "An Example Story")
        #expect(article.bodyXHTML == Self.expectedBody)
    }

    @Test func followsApolloCacheReferences() throws {
        let article = try NYTParser.parse(preloadedData: Fixtures.nytApolloScript)
        #expect(article.headline == "Cached Story")
        #expect(article.byline == "Cache Writer")
        #expect(article.url == "https://www.nytimes.com/2026/11/15/world/cached.html")
        #expect(article.bodyXHTML == "<p><em>First paragraph, by reference.</em></p>\n<p>Second paragraph.</p>\n")
    }

    @Test func headingVariants() throws {
        let content = """
            [{"__typename": "Heading1Block", "content": [{"__typename": "TextInline", "text": "one"}]},
             {"__typename": "Heading4Block", "content": [{"__typename": "TextInline", "text": "four"}]},
             {"__typename": "Heading6Block", "content": [{"__typename": "TextInline", "text": "six"}]},
             {"__typename": "HeadingNBlock", "level": 3, "content": [{"__typename": "TextInline", "text": "n3"}]},
             {"__typename": "HeadingBlock", "content": [{"__typename": "TextInline", "text": "plain"}]},
             {"__typename": "ListBlock", "style": "ORDERED", "content": [{"__typename": "ListItemBlock", "content": [{"__typename": "TextInline", "text": "step"}]}]}]
            """
        let script = "{\"initialData\": {\"data\": {\"article\": \(Fixtures.nytArticleObject(content: content))}}}"
        let body = try NYTParser.parse(preloadedData: script).bodyXHTML
        #expect(body == "<h1>one</h1>\n<h4>four</h4>\n<h4>six</h4>\n<h3>n3</h3>\n<h2>plain</h2>\n<ol>\n<li>\n<p>step</p>\n</li>\n</ol>\n")
    }

    @Test func bylineFallsBackToCreators() throws {
        let script = """
            {"initialData": {"data": {"article": {"headline": "Plain headline", "bylines": [{"creators": [{"displayName": "A"}, {"displayName": "B"}]}],
             "sprinkledBody": {"content": [{"__typename": "ParagraphBlock", "content": [{"__typename": "TextInline", "text": "x"}]}]}}}}}
            """
        let article = try NYTParser.parse(preloadedData: script)
        #expect(article.headline == "Plain headline")
        #expect(article.byline == "A, B")
        #expect(article.firstPublished == nil)
        #expect(article.url == nil)
        let packaged = article.article(fallbackURL: "https://www.nytimes.com/2026/11/15/world/x.html?smid=y", fetchedAt: Date(timeIntervalSince1970: 5))
        #expect(packaged.url == "https://www.nytimes.com/2026/11/15/world/x.html")
        #expect(packaged.source == "The New York Times")
        #expect(packaged.date == Date(timeIntervalSince1970: 5))
    }

    @Test func detectsTheCaptchaPage() {
        #expect(throws: NYTError.captcha) { try NYTParser.parse(pageHTML: Fixtures.nytCaptchaPage) }
        #expect(throws: NYTError.captcha) { try NYTParser.parse(preloadedData: Fixtures.nytCaptchaPage) }
        #expect(throws: NYTError.captcha) { try NYTParser.parse(preloadedData: "__PAPERBOY_CAPTCHA__") }
        #expect(NYTParser.looksLikeCaptcha(Fixtures.nytCaptchaPage))
        #expect(!NYTParser.looksLikeCaptcha(Fixtures.nytPage))
    }

    @Test func distinctErrors() {
        #expect(throws: NYTError.noPreloadedData) { try NYTParser.parse(pageHTML: "<html><body>Nothing here</body></html>") }
        #expect(throws: NYTError.noPreloadedData) { try NYTParser.parse(preloadedData: "") }
        #expect(throws: NYTError.noArticle) { try NYTParser.parse(preloadedData: "window.__preloadedData = {\"initialData\": {\"data\": {\"legacyCollection\": {}}}};") }
        #expect(throws: NYTError.noArticle) {
            try NYTParser.parse(preloadedData: "{\"initialData\": {\"data\": {\"article\": {\"headline\": {\"default\": \"x\"}, \"sprinkledBody\": null}}}}")
        }
        #expect(throws: NYTError.emptyBody) {
            try NYTParser.parse(preloadedData: "{\"initialData\": {\"data\": {\"article\": {\"sprinkledBody\": {\"content\": [{\"__typename\": \"Dropzone\"}]}}}}}")
        }
        #expect(throws: NYTError.self) { try NYTParser.parse(preloadedData: "window.__preloadedData = {\"initialData\": {\"data\": ") }
    }

    @Test func extractionScriptMentionsTheData() {
        #expect(NYTParser.extractionJavaScript.contains("__preloadedData"))
        #expect(NYTParser.extractionJavaScript.contains("JSON.stringify"))
    }
}

@Suite struct NYTDiscoveryTests {
    @Test func parsesRSS() {
        let items = NYTDiscovery.parseFeed(Data(Fixtures.nytRSS.utf8))
        #expect(
            items.map(\.url) == [
                "https://www.nytimes.com/2026/11/15/world/first-story.html",
                "https://www.nytimes.com/live/2026/11/15/world/live-thing",
                "https://www.nytimes.com/2026/11/14/business/second-story.html",
                "https://www.nytimes.com/interactive/2026/11/14/us/map.html",
            ])
        #expect(items[0].title == "First Story & More")
        #expect(items[0].date == Date(timeIntervalSince1970: 1_794_736_811))
        #expect(items[1].title == "Live Updates")
        #expect(items[3].date == nil)
        #expect(items.filter { NYTDiscovery.isArticleURL($0.url) }.count == 2)
        #expect(NYTDiscovery.parseFeed(Data("not xml".utf8)).isEmpty)
    }

    @Test func findsArticleLinksInASectionPage() {
        #expect(
            NYTDiscovery.articleLinks(inSectionHTML: Fixtures.nytSectionHTML) == [
                "https://www.nytimes.com/2026/11/15/world/first-story.html",
                "https://www.nytimes.com/2026/11/14/business/second-story.html",
            ])
    }

    @Test func articleURLRules() {
        #expect(NYTDiscovery.isArticleURL("https://www.nytimes.com/2026/11/15/world/europe/a-story.html"))
        #expect(!NYTDiscovery.isArticleURL("https://www.nytimes.com/section/world"))
        #expect(!NYTDiscovery.isArticleURL("https://www.nytimes.com/interactive/2026/11/15/world/x.html"))
        #expect(!NYTDiscovery.isArticleURL("https://cooking.nytimes.com/2026/11/15/recipes/x.html"))
        #expect(!NYTDiscovery.isArticleURL("garbage"))
    }
}

@Suite struct PageExtractorTests {
    static let moment = Date(timeIntervalSince1970: 1_794_000_000)
    static let filler = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 30)

    @Test func takesTheArticleElementAndTheMetadata() throws {
        let html = """
            <html><head><title>Fallback title | Site</title>
            <meta property="og:title" content="Rain &amp; Shine">
            <meta content="The Daily Example" property="og:site_name">
            <meta name="author" content="Jane Doe">
            <meta property="article:published_time" content="2026-11-10T08:30:00Z">
            </head><body>
            <nav><p>Home News Sport</p></nav>
            <article><header><h1>Rain &amp; Shine</h1><p>By Jane Doe</p></header>
            <p>\(Self.filler)</p><aside><p>Subscribe to our newsletter today</p></aside>
            <p>Second paragraph &amp; more.</p><footer><p>Share this story</p></footer></article>
            <article><p>Related: a short teaser.</p></article>
            <footer><p>Copyright</p></footer></body></html>
            """
        let article = try PageExtractor.article(pageHTML: html, url: "https://www.example.com/news/rain?utm=1")
        #expect(article.title == "Rain & Shine")
        #expect(article.source == "The Daily Example")
        #expect(article.author == "Jane Doe")
        #expect(article.date == ISO8601DateFormatter().date(from: "2026-11-10T08:30:00Z"))
        #expect(article.bodyXHTML.contains("quick brown fox"))
        #expect(article.bodyXHTML.contains("Second paragraph &amp; more."))
        for furniture in ["Subscribe to our newsletter", "Share this story", "Copyright", "Home News Sport", "Related:", "By Jane Doe"] {
            #expect(!article.bodyXHTML.contains(furniture), "\(furniture)")
        }
    }

    @Test func fallsBackToTheBodyAndTheHost() throws {
        let html = "<html><head><title>Plain page</title></head><body><div><p>\(Self.filler)</p></div></body></html>"
        let article = try PageExtractor.article(pageHTML: html, url: "https://www.example.org/x", now: Self.moment)
        #expect(article.title == "Plain page")
        #expect(article.source == "example.org")
        #expect(article.author.isEmpty)
        #expect(article.date == Self.moment)
    }

    @Test func refusesAPageWithoutAnArticle() {
        let html = "<html><body><article><p>Sign in to continue.</p></article><script>var x = \"\(Self.filler)\";</script></body></html>"
        #expect(throws: PageExtractorError.self) {
            _ = try PageExtractor.article(pageHTML: html, url: "https://example.com/login")
        }
    }

    @Test func nestedBlocksAreMatchedToTheirOwnClose() {
        let html = "<div><article id=\"a\"><article id=\"b\">inner</article>outer</article><articles>x</articles></div>"
        #expect(PageExtractor.blocks(named: "article", in: html) == ["<article id=\"a\"><article id=\"b\">inner</article>outer"])
    }

    @Test func sharedPageRoundTrips() throws {
        let page = SharedPage(url: "https://example.com/a", title: "T", html: "<p>x</p>", sharedAt: Self.moment, attempts: 2)
        let back = try JSONDecoder().decode(SharedPage.self, from: JSONEncoder().encode(page))
        #expect(back == page)
        // What the extension writes: no attempts, sharedAt as a number.
        let minimal = try JSONDecoder().decode(SharedPage.self, from: Data(#"{"url":"https://example.com/b","sharedAt":1700000000}"#.utf8))
        #expect(minimal.url == "https://example.com/b" && minimal.html == nil && minimal.attempts == 0)
    }
}
