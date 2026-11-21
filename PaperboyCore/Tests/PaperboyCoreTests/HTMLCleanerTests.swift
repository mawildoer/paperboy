import Foundation
import Testing

@testable import PaperboyCore

@Suite struct HTMLCleanerTests {
    @Test func simpleParagraphs() {
        #expect(HTMLCleaner.clean("<p>One</p><p>Two</p>") == "<p>One</p>\n<p>Two</p>\n")
        #expect(HTMLCleaner.clean("Just text") == "<p>Just text</p>\n")
        #expect(HTMLCleaner.clean("") == "")
        #expect(HTMLCleaner.clean("   \n\t ") == "")
    }

    @Test func inlineFormattingIsKept() {
        let out = HTMLCleaner.clean("<p>A <em>b</em> <i>c</i> <strong>d</strong> <b>e</b> <code>f()</code> g<br>h</p>")
        #expect(out == "<p>A <em>b</em> <i>c</i> <strong>d</strong> <b>e</b> <code>f()</code> g<br/>h</p>\n")
    }

    @Test func headingsAreLimitedToFourLevels() {
        let out = HTMLCleaner.clean("<h1>a</h1><h2>b</h2><h3>c</h3><h4>d</h4><h5>e</h5><h6>f</h6>")
        #expect(out == "<h1>a</h1>\n<h2>b</h2>\n<h3>c</h3>\n<h4>d</h4>\n<h4>e</h4>\n<h4>f</h4>\n")
    }

    @Test func bareAmpersandsAndAngleBracketsAreEscaped() {
        let out = HTMLCleaner.clean("<p>AT&T & co: 1 < 2 > 0, \"quoted\", R&D; &unknown; &#; &</p>")
        #expect(out == "<p>AT&amp;T &amp; co: 1 &lt; 2 &gt; 0, &quot;quoted&quot;, R&amp;D; &amp;unknown; &amp;#; &amp;</p>\n")
        expectWellFormedFragment(out)
    }

    @Test func entitiesAreDecodedToCharacters() {
        let out = HTMLCleaner.clean("<p>a&nbsp;b &mdash; &ldquo;q&rdquo; &eacute; &#233; &#xE9; &#x1F600; &amp;amp; &lt;b&gt; &copy;</p>")
        #expect(out == "<p>a\u{00A0}b — “q” é é é 😀 &amp;amp; &lt;b&gt; ©</p>\n")
        #expect(!out.contains("&nbsp;"))
        expectWellFormedFragment(out)
    }

    @Test func invalidCharacterReferencesNeverReachTheOutput() {
        let out = HTMLCleaner.clean("<p>x&#0;y&#x1F;z&#xD800;w&#99999999;v \u{0}\u{1}\u{8}\u{B}\u{FFFE}\u{FFFF}ok</p>")
        expectWellFormedFragment(out)
        #expect(out.contains("ok"))
        for scalar in out.unicodeScalars {
            #expect(HTMLCleaner.isValidXMLScalar(scalar))
        }
    }

    @Test func unclosedTagsAreBalanced() {
        let out = HTMLCleaner.clean("<p>one <b>bold <i>both<p>two <em>still open")
        #expect(out == "<p>one <b>bold <i>both</i></b></p>\n<p>two <em>still open</em></p>\n")
        expectWellFormedFragment(out)
    }

    @Test func misnestedAndStrayEndTags() {
        let out = HTMLCleaner.clean("</div></p><p>a <b>b <i>c</b> d</i> e</p></span></section>")
        expectWellFormedFragment(out)
        #expect(HTMLCleaner.plainText(out) == "a b c d e")
    }

    @Test func scriptsStylesAndWidgetsAreDropped() {
        let html = """
            <html><head><title>Ignore me</title><style>p { color: red }</style></head><body>
            <script>if (a < b && c > d) { document.write("<p>evil</p>"); }</script>
            <p>Keep this.</p>
            <SCRIPT type="text/javascript">var x = "</p>";</SCRIPT>
            <iframe src="https://example.com"><p>inside iframe</p></iframe>
            <button class="btn">Subscribe</button>
            <form><input type="email"><p>form text</p></form>
            <svg><path d="M0 0"/><text>svg text</text></svg>
            <noscript><p>noscript text</p></noscript>
            <div class="subscription-widget-wrap"><div class="subscription-widget show-subscribe"><p>Subscribe now</p></div></div>
            <p class="button-wrapper"><a class="button primary" href="https://example.com/subscribe"><span>Share</span></a></p>
            <div class="captioned-button-wrap"><div class="preamble"><p>Thanks for reading!</p></div></div>
            <p>And this.</p>
            </body></html>
            """
        let out = HTMLCleaner.clean(html)
        #expect(out == "<p>Keep this.</p>\n<p>And this.</p>\n")
    }

    @Test func imagesAreDroppedButCaptionsKept() {
        let html = """
            <div class="captioned-image-container"><figure><a class="image-link" href="https://cdn.example/x.png">
            <div class="image2-inset"><picture><source srcset="a.webp"><img src="x.png" alt="alt text"></picture>
            <div class="image-link-expand"><button><svg></svg></button></div></div></a>
            <figcaption class="image-caption">A <b>fine</b> caption &amp; credit</figcaption></figure></div>
            <p>After.</p>
            """
        let out = HTMLCleaner.clean(html)
        #expect(out == "<p><em>A fine caption &amp; credit</em></p>\n<p>After.</p>\n")
    }

    @Test func listsAndNesting() {
        let html = "<ul><li>One<li><p>Two</p><ol><li>Two-a</li></ol></li>stray<li></li></ul>"
        let out = HTMLCleaner.clean(html)
        #expect(
            out == """
                <ul>
                <li>
                <p>One</p>
                </li>
                <li>
                <p>Two</p>
                <ol>
                <li>
                <p>Two-a</p>
                </li>
                </ol>
                </li>
                <li>
                <p>stray</p>
                </li>
                </ul>

                """)
        expectWellFormedFragment(out)
    }

    @Test func blockquoteAndRulesAndPre() {
        let html = "<blockquote>Quoted <em>text</em><p>second</p></blockquote><hr><pre><code>let a = 1 &lt; 2\n  indented &amp; kept</code></pre><blockquote>  </blockquote>"
        let out = HTMLCleaner.clean(html)
        #expect(
            out == """
                <blockquote>
                <p>Quoted <em>text</em></p>
                <p>second</p>
                </blockquote>
                <hr/>
                <pre>let a = 1 &lt; 2
                  indented &amp; kept</pre>

                """)
        expectWellFormedFragment(out)
    }

    @Test func linksLoseTheirTargetByDefault() {
        let html = "<p>See <a href=\"https://example.com/?a=1&amp;b=2\">this <b>page</b></a> and <a href=\"javascript:alert(1)\">that</a>.</p>"
        #expect(HTMLCleaner.clean(html) == "<p>See this <b>page</b> and that.</p>\n")
        let kept = HTMLCleaner.clean(html, options: .init(keepLinks: true))
        #expect(kept == "<p>See <a href=\"https://example.com/?a=1&amp;b=2\">this <b>page</b></a> and that.</p>\n")
        expectWellFormedFragment(kept)
    }

    @Test func whitespaceIsCollapsed() {
        let out = HTMLCleaner.clean("<div>\n  <p>\n   spaced \n\t out   <em> text </em>  here \n</p>\n</div>")
        #expect(out == "<p>spaced out <em>text </em>here </p>\n")
    }

    @Test func divsAndSpansAreTransparent() {
        let out = HTMLCleaner.clean("<div>alpha<div>beta <span class=\"x\">gamma</span></div>delta</div><table><tr><td>cell</td></tr></table>")
        #expect(out == "<p>alpha</p>\n<p>beta gamma</p>\n<p>delta</p>\n<p>cell</p>\n")
    }

    @Test func commentsDoctypeAndCDATA() {
        let out = HTMLCleaner.clean("<!DOCTYPE html><!-- a <p>comment</p> --><?php echo 1 ?><p>x<![CDATA[ <raw> & ]]>y</p><!-- unterminated")
        #expect(out == "<p>x &lt;raw&gt; &amp; y</p>\n")
    }

    @Test func attributesWithOddQuoting() {
        let html = "<p class=a title='it\"s' data-x=\"1>2\" onclick=alert(1) =broken>ok</p><a href=unquoted>link</a><p title=\"never closed>lost"
        let out = HTMLCleaner.clean(html)
        expectWellFormedFragment(out)
        #expect(out.hasPrefix("<p>ok</p>\n<p>link</p>\n"))
    }

    @Test func truncatedInput() {
        for html in ["<p>cut <", "<p>cut <b", "<p>cut <b class=\"x", "<p>cut </", "<p>cut &amp", "<p>cut &#12", "<", "<<<>>>", "</", "<p", "&", "<!--", "<![CDATA["] {
            let out = HTMLCleaner.clean(html)
            expectWellFormedFragment(out)
        }
    }

    @Test func deepNestingDoesNotOverflow() {
        let depth = 20_000
        let html = String(repeating: "<div><b>", count: depth) + "deep" + String(repeating: "</b></div>", count: depth)
        let out = HTMLCleaner.clean(html)
        expectWellFormedFragment(out)
        #expect(HTMLCleaner.plainText(out) == "deep")
    }

    @Test func outputUsesOnlyTheAllowedElements() {
        let html = """
            <article><header><h1>T</h1><h5>five</h5></header><section><p>p <u>u</u> <s>s</s> <sup>1</sup> <mark>m</mark> <font color=red>f</font>
            <q>quoted</q> <abbr title="x">abbr</abbr></p><dl><dt>term</dt><dd>definition</dd></dl>
            <table><thead><tr><th>h</th></tr></thead><tbody><tr><td>d</td></tr></tbody></table>
            <details><summary>sum</summary>det</details><figure><img src=x><figcaption>cap</figcaption></figure>
            <video controls><source src=x>fallback</video><audio>a</audio><object>o</object><embed src=x>
            <ol><li>li</li></ol><pre>pre</pre><hr><blockquote>bq</blockquote></section><footer>foot</footer></article>
            """
        let out = HTMLCleaner.clean(html, options: .init(keepLinks: true))
        expectWellFormedFragment(out)
        #expect(elementNames(in: out).isSubset(of: allowedElements))
        let text = HTMLCleaner.plainText(out)
        for expected in ["five", "term", "definition", "sum", "det", "cap", "“quoted”", "foot"] { #expect(text.contains(expected)) }
        for dropped in ["fallback", "abbr title"] { #expect(!text.contains(dropped)) }
    }

    /// A realistic Substack body, with the furniture Substack puts around the text.
    @Test func substackBody() {
        let out = HTMLCleaner.clean(Fixtures.substackBodyHTML)
        expectWellFormedFragment(out)
        #expect(elementNames(in: out).isSubset(of: allowedElements))
        #expect(out.contains("<h2>A heading</h2>"))
        #expect(out.contains("<p>First paragraph with <em>emphasis</em>, a link and an ampersand: R&amp;D.</p>"))
        #expect(out.contains("<blockquote>\n<p>A quoted passage.</p>\n</blockquote>"))
        #expect(out.contains("<p><em>Chart: something going up</em></p>"))
        #expect(out.contains("<li>\n<p>First point</p>\n</li>"))
        #expect(out.contains("footnote text"))
        #expect(!out.contains("Subscribe"))
        #expect(!out.contains("Share"))
        #expect(!out.contains("img"))
        #expect(!out.contains("Type your email"))
    }

    /// Random garbage in, well-formed XML out. A fixed seed keeps failures reproducible.
    @Test func fuzzAlwaysProducesWellFormedXML() {
        var generator = SplitMix64(seed: 0x00C0_FFEE)
        let pieces = [
            "<p>", "</p>", "<div>", "</div>", "<b>", "</b>", "<i>", "</em>", "<ul>", "<li>", "</ul>", "<blockquote>", "</blockquote>",
            "<a href=\"x&y\">", "</a>", "<br>", "<hr/>", "<pre>", "</pre>", "<script>", "</script>", "<style>", "<!--", "-->", "<![CDATA[", "]]>",
            "&", "&amp;", "&nbsp;", "&#x0;", "&#55357;", "&bogus;", "<", ">", "\"", "'", "text ", "más ", "日本語", "\u{0}", "\u{1F}", "\n", "  ",
            "<h1>", "</h1>", "<h7>", "<figcaption>", "</figcaption>", "<table><tr><td>", "<img src=x>", "<span class='subscription-widget'>",
            "</span>", "<svg>", "</svg>", "<button>", "</button>", "<p class=\"", "<a href=", "=", "/>", "</", "<?", "?>", "<!doctype",
        ]
        var documents: [String] = []
        for _ in 0..<300 {
            var html = ""
            for _ in 0..<Int(generator.next() % 40 + 1) { html += pieces[Int(generator.next() % UInt64(pieces.count))] }
            documents.append(html)
        }
        // One XMLParser pass per document, plus a single xmllint run over all of them.
        var combined = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<all>\n"
        for html in documents {
            let out = HTMLCleaner.clean(html, options: .init(keepLinks: true))
            let parser = XMLParser(data: Data("<body>\(out)</body>".utf8))
            #expect(parser.parse(), "input: \(html.debugDescription)\noutput: \(out.debugDescription)")
            #expect(elementNames(in: out).isSubset(of: allowedElements), "input: \(html.debugDescription)")
            combined += "<doc>\(out)</doc>\n"
        }
        combined += "</all>\n"
        expectWellFormed(combined)
    }
}

struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
