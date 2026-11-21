import Foundation

/// Fixtures built by hand to match the documented shapes. They are NOT captures of real
/// responses; the real endpoints still have to be checked on the phone.
enum Fixtures {
    static let substackBodyHTML = """
        <div class="captioned-image-container"><figure><a target="_blank" class="image-link image2 is-viewable-img" href="https://substackcdn.com/image/fetch/x.png"><div class="image2-inset"><picture><source type="image/webp" srcset="https://substackcdn.com/image/fetch/w_424/x.png 424w"/><img src="https://substackcdn.com/image/fetch/x.png" width="1456" height="816" alt="" class="sizing-normal"/></picture><div class="image-link-expand"><div class="pencraft pc-display-flex"><button tabindex="0" type="button" class="pencraft pc-reset"><svg xmlns="http://www.w3.org/2000/svg" width="20" height="20"><path d="M1 1"/></svg></button></div></div></div></a><figcaption class="image-caption">Chart: something going up</figcaption></figure></div>
        <p>First paragraph with <em>emphasis</em>, a <a href="https://example.com/a?b=1&amp;c=2" rel="">link</a> and an ampersand: R&amp;D.</p>
        <div class="subscription-widget-wrap-editor" data-attrs="{&quot;url&quot;:&quot;https://example.substack.com/subscribe?&quot;,&quot;text&quot;:&quot;Subscribe&quot;}" data-component-name="SubscribeWidgetToDOM"><div class="subscription-widget show-subscribe"><div class="preamble"><p class="cta-caption">Thanks for reading! Subscribe for free to receive new posts.</p></div><form class="subscription-widget-subscribe"><input type="email" class="email-input" name="email" placeholder="Type your email…" tabindex="-1"><input type="submit" class="button primary" value="Subscribe"><div class="fake-input-wrapper"><div class="fake-input"></div><div class="fake-button"></div></div></form></div></div>
        <h2 class="header-anchor-post">A heading<div class="pencraft pc-display-flex header-anchor-parent"><div class="pencraft pc-display-contents pc-reset pubTheme-yiXxQA"><div id="§a-heading" class="pencraft pc-reset header-anchor offset-top"></div><button tabindex="0" type="button" aria-label="Link" class="pencraft pc-reset"><svg width="18" height="18"><path d="M10 13"></path></svg></button></div></div></h2>
        <blockquote><p>A quoted passage.</p></blockquote>
        <ul><li><p>First point</p></li><li><p>Second point with <strong>bold</strong></p></li></ul>
        <p>A sentence with a footnote.<a class="footnote-anchor" data-component-name="FootnoteAnchorToDOM" id="footnote-anchor-1" href="#footnote-1" target="_self">1</a></p>
        <p class="button-wrapper" data-attrs="{&quot;url&quot;:&quot;https://example.substack.com/p/hello?utm_source=substack&amp;action=share&quot;,&quot;text&quot;:&quot;Share&quot;}" data-component-name="ButtonCreateButton"><a class="button primary" href="https://example.substack.com/p/hello?action=share"><span>Share</span></a></p>
        <div><hr></div>
        <div class="footnote" data-component-name="FootnoteToDOM"><a id="footnote-1" href="#footnote-anchor-1" class="footnote-number" contenteditable="false" target="_self">1</a><div class="footnote-content"><p>The footnote text.</p></div></div>
        """

    static func jsonString(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// `GET https://<publication>/api/v1/posts/<slug>`
    static var substackPostJSON: String {
        """
        {
          "id": 123456789,
          "publication_id": 4242,
          "title": "Hello & welcome",
          "social_title": null,
          "subtitle": "A subtitle with <angle> brackets",
          "slug": "hello",
          "type": "newsletter",
          "post_date": "2026-11-14T15:30:00.000Z",
          "audience": "only_paid",
          "canonical_url": "https://example.substack.com/p/hello",
          "wordcount": 1234,
          "cover_image": "https://substackcdn.com/image/fetch/cover.png",
          "reactions": {"❤": 12},
          "publishedBylines": [
            {"id": 1, "name": "Jane Writer", "handle": "jane", "photo_url": null, "bio": "x",
             "publicationUsers": [{"id": 9, "role": "admin", "publication": {"id": 4242, "name": "The Example Letter", "subdomain": "example", "custom_domain": null}}]},
            {"id": 2, "name": "Sam Coauthor"}
          ],
          "body_html": \(jsonString(substackBodyHTML)),
          "truncated_body_text": "First paragraph with emphasis…"
        }
        """
    }

    /// `GET https://<publication>/api/v1/archive?sort=new&offset=0&limit=12`
    static let substackArchiveJSON = """
        [
          {"id": 3, "title": "Newest post", "slug": "newest-post", "post_date": "2026-11-15T09:00:00.000Z", "audience": "only_paid",
           "type": "newsletter", "canonical_url": "https://example.substack.com/p/newest-post", "subtitle": "s", "wordcount": 900},
          {"id": 2, "title": "A podcast", "slug": "a-podcast", "post_date": "2026-11-12T09:00:00.000Z", "audience": "everyone",
           "type": "podcast", "canonical_url": "https://example.substack.com/p/a-podcast"},
          {"id": 1, "title": "Hello & welcome", "slug": "hello", "post_date": "2026-11-14T15:30:00.000Z", "audience": "only_paid",
           "type": "newsletter", "canonical_url": "https://example.substack.com/p/hello"},
          {"id": 0, "title": "No URL, skipped", "slug": "broken"}
        ]
        """

    /// The reader inbox on substack.com (shape unverified): posts wrapped in an object, some nested.
    static let substackInboxJSON = """
        {
          "posts": [
            {"id": 30, "title": "From publication A", "slug": "from-a", "post_date": "2026-11-15T08:00:00.000Z", "audience": "only_paid",
             "canonical_url": "https://a.substack.com/p/from-a", "type": "newsletter"},
            {"post": {"id": 31, "title": "From publication B", "slug": "from-b", "post_date": "2026-11-15T07:00:00Z",
             "canonical_url": "https://www.custom-domain.example/p/from-b", "audience": "everyone"}, "publication": {"name": "B"}},
            {"id": 30, "title": "Duplicate", "canonical_url": "https://a.substack.com/p/from-a"},
            {"type": "note", "body": "not a post"}
          ],
          "publications": [
            {"id": 1, "name": "A", "subdomain": "a", "custom_domain": null},
            {"id": 2, "name": "B", "subdomain": "b", "custom_domain": "www.custom-domain.example"}
          ],
          "more": true
        }
        """

    // MARK: NYT

    /// The body blocks of an article, as in `sprinkledBody.content`.
    static let nytContent = """
        [
          {"__typename": "HeaderBasicBlock", "headline": {"__typename": "Heading1Block", "content": [{"__typename": "TextInline", "text": "Headline in the Header", "formats": []}]},
           "summary": {"__typename": "SummaryBlock", "content": [{"__typename": "TextInline", "text": "A one-line summary.", "formats": []}]},
           "ledeMedia": {"__typename": "ImageBlock", "media": {"__typename": "Image", "caption": {"__typename": "TextOnlyDocumentBlock", "text": "Lede caption"}, "credit": "Photo by Someone"}},
           "byline": {"__typename": "BylineBlock", "bylines": [{"renderedRepresentation": "By Jane Reporter"}]},
           "timestampBlock": {"__typename": "TimestampBlock", "timestamp": "2026-11-15T10:00:00.000Z"}},
          {"__typename": "ParagraphBlock", "content": [
            {"__typename": "TextInline", "text": "Plain text, then ", "formats": []},
            {"__typename": "TextInline", "text": "bold", "formats": [{"__typename": "BoldFormat"}]},
            {"__typename": "TextInline", "text": " and ", "formats": []},
            {"__typename": "TextInline", "text": "bold italic link", "formats": [{"__typename": "BoldFormat"}, {"__typename": "ItalicFormat"}, {"__typename": "LinkFormat", "url": "https://www.nytimes.com/x?a=1&b=2", "title": undefined}]},
            {"__typename": "TextInline", "text": " & a <tag> that must be escaped.", "formats": []}
          ]},
          {"__typename": "Dropzone", "index": 0, "bad": undefined},
          {"__typename": "Heading2Block", "textAlign": "LEFT", "content": [{"__typename": "TextInline", "text": "A subheading", "formats": []}]},
          {"__typename": "ImageBlock", "media": {"__typename": "Image", "caption": {"__typename": "TextOnlyDocumentBlock", "text": "People standing somewhere."}, "credit": "Jane Doe for The New York Times", "crops": [{"renditions": [{"url": "https://static01.nyt.com/x.jpg"}]}]}},
          {"__typename": "BlockquoteBlock", "content": [{"__typename": "ParagraphBlock", "content": [{"__typename": "TextInline", "text": "Quoted words.", "formats": [{"__typename": "ItalicFormat"}]}]}]},
          {"__typename": "ListBlock", "style": "UNORDERED", "content": [
            {"__typename": "ListItemBlock", "content": [{"__typename": "ParagraphBlock", "content": [{"__typename": "TextInline", "text": "Item one", "formats": []}]}]},
            {"__typename": "ListItemBlock", "content": [{"__typename": "ParagraphBlock", "content": [{"__typename": "TextInline", "text": "Item two", "formats": []}, {"__typename": "LineBreakInline"}, {"__typename": "TextInline", "text": "second line"}]}]}
          ]},
          {"__typename": "RuleBlock"},
          {"__typename": "Heading3Block", "content": [{"__typename": "TextInline", "text": "Smaller heading", "formats": []}]},
          {"__typename": "EmailSignupBlock", "content": [{"__typename": "TextInline", "text": "Sign up for the newsletter"}]},
          {"__typename": "RelatedLinksBlock", "displayName": "Related", "related": [{"headline": {"default": "Other article"}}]},
          {"__typename": "DetailBlock", "content": [{"__typename": "TextInline", "text": "A reporter contributed from somewhere.", "formats": []}]},
          {"__typename": "SomeFutureBlock", "content": [{"__typename": "ParagraphBlock", "content": [{"__typename": "TextInline", "text": "Text inside an unknown block survives.", "formats": []}]}]},
          {"__typename": "ParagraphBlock", "content": [{"__typename": "TextInline", "text": "The word undefined inside a string, and \\"undefined\\" in quotes, stay.", "formats": []}]}
        ]
        """

    static func nytArticleObject(content: String = nytContent) -> String {
        """
        {
          "__typename": "Article",
          "id": "QXJ0aWNsZTpueXQ6Ly9hcnRpY2xlLzEyMw==",
          "url": "https://www.nytimes.com/2026/11/15/world/example-story.html",
          "headline": {"__typename": "CreativeWorkHeadline", "default": "An Example Story", "seo": undefined},
          "summary": "A one-line summary.",
          "firstPublished": "2026-11-15T10:00:11.000Z",
          "lastModified": "2026-11-15T12:00:00.000Z",
          "bylines": [{"__typename": "Byline", "renderedRepresentation": "By Jane Reporter and John Correspondent", "creators": [{"displayName": "Jane Reporter"}, {"displayName": "John Correspondent"}]}],
          "section": {"displayName": "World"},
          "sprinkledBody": {"__typename": "DocumentBlock", "content": \(content)}
        }
        """
    }

    /// The script as it appears in the page: a JavaScript object literal with bare `undefined`.
    static var nytPreloadedScript: String {
        """
        window.__preloadedData = {"initialData": {"data": {"article": \(nytArticleObject()), "viewer": undefined}}, "loaderData": {}, "initialState": {}, "config": {"gqlUrlClient": "https://samizdat-graphql.nytimes.com/graphql/v2", "flag": undefined}};
        """
    }

    static var nytPage: String {
        """
        <!DOCTYPE html><html lang="en"><head><title>An Example Story - The New York Times</title>
        <script>window.__other = {"a": 1};</script></head><body><div id="app"><p>Server-rendered text</p></div>
        <script>\(nytPreloadedScript)</script>
        <script>window.__after = true;</script></body></html>
        """
    }

    /// The newer layout: the article under loaderData, initialData present but empty.
    static var nytLoaderDataScript: String {
        """
        window.__preloadedData = {"initialData": {}, "loaderData": {"data": {"article": \(nytArticleObject())}}, "initialState": {}};
        """
    }

    /// An Apollo-cache layout: the article is only reachable through references.
    static let nytApolloScript = """
        window.__preloadedData = {"initialData": {}, "initialState": {
          "ROOT_QUERY": {"article({\\"id\\":\\"/2026/11/15/world/cached.html\\"})": {"__ref": "Article:abc"}},
          "Article:abc": {"__typename": "Article", "url": "https://www.nytimes.com/2026/11/15/world/cached.html",
            "headline": {"__ref": "Headline:abc"}, "firstPublished": "2026-11-15T06:00:00Z",
            "bylines": [{"__ref": "Byline:1"}], "sprinkledBody": {"__ref": "Body:abc"}},
          "Headline:abc": {"__typename": "CreativeWorkHeadline", "default": "Cached Story"},
          "Byline:1": {"__typename": "Byline", "renderedRepresentation": "By Cache Writer"},
          "Body:abc": {"__typename": "DocumentBlock", "content": [{"__ref": "Para:1"}, {"__ref": "Para:2"}]},
          "Para:1": {"__typename": "ParagraphBlock", "content": [{"__ref": "Text:1"}]},
          "Para:2": {"__typename": "ParagraphBlock", "content": [{"__typename": "TextInline", "text": "Second paragraph.", "formats": []}]},
          "Text:1": {"__typename": "TextInline", "text": "First paragraph, by reference.", "formats": [{"__typename": "ItalicFormat"}]}
        }};
        """

    static let nytCaptchaPage = """
        <html lang="en"><head><title>nytimes.com</title><style>#cmsg{animation: A 1.5s;}</style></head><body style="margin:0">
        <p id="cmsg">Please enable JS and disable any ad blocker</p>
        <script data-cfasync="false">var dd={'rt':'c','cid':'AHrlqAAAAAMA','hsh':'499AE34129FA4E4FABC31582C3075D','t':'bv','s':17439,'host':'geo.captcha-delivery.com'}</script>
        <script data-cfasync="false" src="https://ct.captcha-delivery.com/c.js"></script></body></html>
        """

    static let nytRSS = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:atom="http://www.w3.org/2005/Atom" version="2.0">
          <channel>
            <title>NYT &gt; Top Stories</title>
            <link>https://www.nytimes.com</link>
            <atom:link href="https://rss.nytimes.com/services/xml/rss/nyt/HomePage.xml" rel="self" type="application/rss+xml"/>
            <item>
              <title>First Story &amp; More</title>
              <link>https://www.nytimes.com/2026/11/15/world/first-story.html</link>
              <guid isPermaLink="true">https://www.nytimes.com/2026/11/15/world/first-story.html</guid>
              <atom:link href="https://www.nytimes.com/2026/11/15/world/first-story.html" rel="standout"/>
              <description>Summary.</description>
              <dc:creator>Jane Reporter</dc:creator>
              <pubDate>Sun, 15 Nov 2026 10:00:11 +0000</pubDate>
            </item>
            <item>
              <title><![CDATA[Live Updates]]></title>
              <link>https://www.nytimes.com/live/2026/11/15/world/live-thing</link>
              <pubDate>Sun, 15 Nov 2026 09:00:00 +0000</pubDate>
            </item>
            <item>
              <title>Second Story</title>
              <link>https://www.nytimes.com/2026/11/14/business/second-story.html?smid=rss</link>
              <pubDate>Sat, 14 Nov 2026 22:30:00 +0000</pubDate>
            </item>
            <item>
              <title>An Interactive</title>
              <link>https://www.nytimes.com/interactive/2026/11/14/us/map.html</link>
            </item>
          </channel>
        </rss>
        """

    static let nytSectionHTML = """
        <section><a href="/2026/11/15/world/first-story.html">First</a>
        <a href="https://www.nytimes.com/2026/11/15/world/first-story.html?campaign=x">First again</a>
        <a href='/2026/11/14/business/second-story.html#after-top'>Second</a>
        <a href="/interactive/2026/11/14/us/map.html">Map</a><a href="/section/world">World</a>
        <a href="https://www.example.com/2026/11/14/other/site.html">Elsewhere</a>
        <a href="/video/world/100000001.html">Video</a></section>
        """
}
