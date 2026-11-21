import Foundation

/// Turns arbitrary article HTML into a well-formed XHTML fragment limited to
/// p, h1–h4, blockquote, ul/ol/li, em/i, strong/b, a, br, hr, pre and code.
///
/// The output is always well-formed XML: every tag is balanced, text is escaped, the only
/// entities used are `&amp;`, `&lt;`, `&gt;` and `&quot;`, and characters that XML 1.0 forbids
/// are removed. The parser on the device is expat, which stops at the first error.
public enum HTMLCleaner {
    public struct Options: Sendable {
        /// Keep `<a href>` for http(s) links. Off by default: the reader has no network, and
        /// plain text is the cheapest thing for it to lay out.
        public var keepLinks = false
        /// Elements nested deeper than this are flattened into their ancestor.
        public var maxDepth = 150

        public init(keepLinks: Bool = false, maxDepth: Int = 150) {
            self.keepLinks = keepLinks
            self.maxDepth = maxDepth
        }
    }

    /// Clean a document or fragment. Returns block-level XHTML (possibly empty).
    public static func clean(_ html: String, options: Options = Options()) -> String {
        let root = HTMLTreeBuilder.build(html, maxDepth: max(8, options.maxDepth))
        var emitter = Emitter(options: options)
        emitter.walk(root.children)
        return emitter.finish()
    }

    /// The text of a document with all markup removed and whitespace collapsed.
    public static func plainText(_ html: String) -> String {
        let root = HTMLTreeBuilder.build(html, maxDepth: 150)
        return collapseWhitespace(textContent(of: root.children, preserveBreaks: false))
    }

    /// Escape text for use as XML character data or inside a double-quoted attribute.
    public static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count + 16)
        appendEscaped(text, to: &out)
        return out
    }

    static func appendEscaped(_ text: String, to out: inout String) {
        for scalar in text.unicodeScalars {
            appendEscaped(scalar, to: &out)
        }
    }

    static func appendEscaped(_ scalar: Unicode.Scalar, to out: inout String) {
        switch scalar {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        default:
            if isValidXMLScalar(scalar) { out.unicodeScalars.append(scalar) }
        }
    }

    /// XML 1.0 `Char` production.
    static func isValidXMLScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x9, 0xA, 0xD, 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF: return true
        default: return false
        }
    }

    static func isHTMLSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x20, 0x09, 0x0A, 0x0C, 0x0D: return true
        default: return false
        }
    }

    static func collapseWhitespace(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            if isHTMLSpace(scalar) {
                pendingSpace = !out.isEmpty
            } else {
                if pendingSpace { out.append(" ") }
                pendingSpace = false
                out.append(scalar)
            }
        }
        return String(out)
    }

    static func textContent(of children: [HTMLChild], preserveBreaks: Bool) -> String {
        var out = ""
        func visit(_ children: [HTMLChild]) {
            for child in children {
                switch child {
                case .text(let text): out += text
                case .element(let node):
                    if Emitter.isDropped(node) { continue }
                    if node.name == "br" { out += preserveBreaks ? "\n" : " " }
                    let isBlock = Emitter.blockTransparent.contains(node.name) || node.name == "p"
                    if isBlock, !preserveBreaks { out += " " }
                    visit(node.children)
                    if isBlock { out += preserveBreaks ? "\n" : " " }
                }
            }
        }
        visit(children)
        return out
    }
}

// MARK: - Emitter

private struct Emitter {
    let options: HTMLCleaner.Options

    /// Stack of output buffers; block containers (blockquote, ul, li) push one so that an
    /// empty container can be dropped instead of emitted.
    private var out: [String] = [""]

    private var paraOpen = false
    private var paraTag = "p"
    private var para = ""
    private var paraHasContent = false
    private var lastWasSpace = true
    private var inlineStack: [String] = []
    /// Bumped whenever a paragraph is opened or closed; an inline element only writes its
    /// end tag if the paragraph it was opened in is still the current one.
    private var generation = 0

    init(options: HTMLCleaner.Options) {
        self.options = options
    }

    static let dropped: Set<String> = [
        "script", "style", "iframe", "button", "form", "svg", "math", "noscript", "template", "video", "audio",
        "object", "embed", "select", "input", "textarea", "canvas", "head", "title", "nav", "img", "picture",
        "source", "track", "link", "meta", "map", "area", "dialog", "label", "frame", "frameset", "applet",
    ]

    /// Elements that only mark a paragraph boundary.
    static let blockTransparent: Set<String> = [
        "div", "section", "article", "main", "header", "footer", "aside", "figure", "address", "center", "details",
        "summary", "dl", "dt", "dd", "table", "thead", "tbody", "tfoot", "tr", "td", "th", "caption", "li", "body",
        "html", "fieldset", "hgroup", "menu",
    ]

    static let inlineKept: Set<String> = ["em", "i", "strong", "b", "code"]

    /// Class names that mark page furniture: Substack subscribe boxes, share buttons, polls…
    static let droppedClassTokens: Set<String> = [
        "button-wrapper", "captioned-button-wrap", "install-substack-app-embed", "poll-embed", "paywall-jump",
        "image-link-expand", "subscribe-widget", "subscription-widget", "subscription-widget-wrap",
        "subscription-widget-wrap-editor", "share-dialog", "native-video-embed", "native-audio-embed", "audio-embed",
        "youtube-wrap", "vimeo-wrap", "comments-section",
    ]

    static func isDropped(_ node: HTMLNode) -> Bool {
        if dropped.contains(node.name) { return true }
        if let classes = node.attributes["class"] {
            for token in classes.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }) {
                let name = token.lowercased()
                if droppedClassTokens.contains(name) || name.hasPrefix("subscription-widget") || name.hasPrefix("subscribe-widget") {
                    return true
                }
            }
        }
        if node.attributes["hidden"] != nil || node.attributes["aria-hidden"] == "true" { return true }
        return false
    }

    mutating func finish() -> String {
        flushParagraph()
        while out.count > 1 {
            let inner = out.removeLast()
            out[out.count - 1] += inner
        }
        return out[0]
    }

    // MARK: Paragraph handling

    private mutating func beginParagraph(_ tag: String) {
        flushParagraph()
        paraOpen = true
        paraTag = tag
        para = ""
        paraHasContent = false
        lastWasSpace = true
        inlineStack = []
        generation += 1
    }

    private mutating func flushParagraph() {
        guard paraOpen else { return }
        for tag in inlineStack.reversed() { para += "</\(tag)>" }
        if paraHasContent {
            out[out.count - 1] += "<\(paraTag)>\(para)</\(paraTag)>\n"
        }
        paraOpen = false
        para = ""
        inlineStack = []
        generation += 1
    }

    private mutating func appendText(_ text: String) {
        if !paraOpen {
            // Whitespace between blocks is not content.
            guard text.unicodeScalars.contains(where: { !HTMLCleaner.isHTMLSpace($0) }) else { return }
            beginParagraph("p")
        }
        for scalar in text.unicodeScalars {
            if HTMLCleaner.isHTMLSpace(scalar) {
                if !lastWasSpace {
                    para += " "
                    lastWasSpace = true
                }
            } else if HTMLCleaner.isValidXMLScalar(scalar) {
                HTMLCleaner.appendEscaped(scalar, to: &para)
                lastWasSpace = false
                paraHasContent = true
            }
        }
    }

    private mutating func openInline(_ tag: String, attributes: String = "") -> Int {
        if !paraOpen { beginParagraph("p") }
        para += "<\(tag)\(attributes)>"
        inlineStack.append(tag)
        return generation
    }

    private mutating func closeInline(_ openedIn: Int) {
        guard paraOpen, openedIn == generation, let tag = inlineStack.popLast() else { return }
        para += "</\(tag)>"
    }

    private mutating func emitBlock(_ xml: String) {
        flushParagraph()
        out[out.count - 1] += xml
    }

    /// Run `body` into a fresh buffer and return what it produced.
    private mutating func capture(_ body: (inout Emitter) -> Void) -> String {
        flushParagraph()
        out.append("")
        body(&self)
        flushParagraph()
        return out.removeLast()
    }

    // MARK: Tree walk

    mutating func walk(_ children: [HTMLChild]) {
        for child in children {
            switch child {
            case .text(let text): appendText(text)
            case .element(let node): visit(node)
            }
        }
    }

    private mutating func visit(_ node: HTMLNode) {
        if Self.isDropped(node) { return }
        let name = node.name
        switch name {
        case "p":
            beginParagraph("p")
            walk(node.children)
            flushParagraph()
        case "h1", "h2", "h3", "h4":
            beginParagraph(name)
            walk(node.children)
            flushParagraph()
        case "h5", "h6":
            beginParagraph("h4")
            walk(node.children)
            flushParagraph()
        case "blockquote":
            let inner = capture { $0.walk(node.children) }
            if !inner.isEmpty { emitBlock("<blockquote>\n\(inner)</blockquote>\n") }
        case "ul", "ol":
            let inner = capture { $0.walkList(node.children) }
            if !inner.isEmpty { emitBlock("<\(name)>\n\(inner)</\(name)>\n") }
        case "pre":
            var text = HTMLCleaner.textContent(of: node.children, preserveBreaks: true)
            if text.hasPrefix("\n") { text.removeFirst() }
            while let last = text.unicodeScalars.last, HTMLCleaner.isHTMLSpace(last) { text.unicodeScalars.removeLast() }
            if !text.isEmpty { emitBlock("<pre>\(HTMLCleaner.escape(text))</pre>\n") }
        case "hr":
            emitBlock("<hr/>\n")
        case "br":
            if paraOpen, paraHasContent {
                para += "<br/>"
                lastWasSpace = true
            }
        case "figcaption":
            let text = HTMLCleaner.collapseWhitespace(HTMLCleaner.textContent(of: node.children, preserveBreaks: false))
            if !text.isEmpty { emitBlock("<p><em>\(HTMLCleaner.escape(text))</em></p>\n") }
        case "a":
            if options.keepLinks, let href = node.attributes["href"], Self.isSafeLink(href) {
                let opened = openInline("a", attributes: " href=\"\(HTMLCleaner.escape(href))\"")
                walk(node.children)
                closeInline(opened)
            } else if (node.attributes["class"] ?? "").contains("footnote-anchor") || (node.attributes["class"] ?? "").contains("footnote-number") {
                // Substack footnote markers: "text.1" reads badly without the link styling.
                appendText("[")
                walk(node.children)
                appendText("]")
            } else {
                walk(node.children)
            }
        case "q":
            appendText("\u{201C}")
            walk(node.children)
            appendText("\u{201D}")
        default:
            if Self.inlineKept.contains(name) {
                let opened = openInline(name)
                walk(node.children)
                closeInline(opened)
            } else if Self.blockTransparent.contains(name) {
                flushParagraph()
                walk(node.children)
                flushParagraph()
            } else {
                // span, sup, sub, u, s, small, mark, font, time, cite, abbr and anything unknown.
                walk(node.children)
            }
        }
    }

    /// Children of ul/ol. Anything that is not an li is gathered into an li of its own.
    private mutating func walkList(_ children: [HTMLChild]) {
        var stray: [HTMLChild] = []
        func flushStray(_ emitter: inout Emitter) {
            guard !stray.isEmpty else { return }
            let pending = stray
            stray = []
            emitter.emitListItem(pending)
        }
        for child in children {
            if case .element(let node) = child, node.name == "li" {
                flushStray(&self)
                if !Self.isDropped(node) { emitListItem(node.children) }
            } else {
                stray.append(child)
            }
        }
        flushStray(&self)
    }

    private mutating func emitListItem(_ children: [HTMLChild]) {
        let inner = capture { $0.walk(children) }
        if !inner.isEmpty { emitBlock("<li>\n\(inner)</li>\n") }
    }

    private static func isSafeLink(_ href: String) -> Bool {
        let lower = href.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }
}

// MARK: - Tree

final class HTMLNode {
    let name: String
    let attributes: [String: String]
    var children: [HTMLChild] = []

    init(name: String, attributes: [String: String] = [:]) {
        self.name = name
        self.attributes = attributes
    }
}

enum HTMLChild {
    case text(String)
    case element(HTMLNode)
}

enum HTMLTreeBuilder {
    static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr",
    ]

    /// A start tag of one of these closes an open `<p>`.
    static let closesParagraph: Set<String> = [
        "address", "article", "aside", "blockquote", "details", "div", "dl", "fieldset", "figcaption", "figure",
        "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "main", "nav", "ol", "p", "pre",
        "section", "table", "ul", "li",
    ]

    /// An open `<p>` is not looked for beyond one of these.
    static let paragraphScope: Set<String> = [
        "blockquote", "li", "div", "td", "th", "section", "article", "figure", "ul", "ol", "table", "button",
        "aside", "main", "header", "footer", "details", "figcaption", "dd", "dt", "caption",
    ]

    static func build(_ html: String, maxDepth: Int) -> HTMLNode {
        let root = HTMLNode(name: "#root")
        var stack: [HTMLNode] = [root]
        var tokenizer = HTMLTokenizer(html)

        func current() -> HTMLNode { stack[stack.count - 1] }

        func closeOpenParagraph() {
            var index = stack.count - 1
            while index > 0 {
                let name = stack[index].name
                if name == "p" {
                    stack.removeSubrange(index...)
                    return
                }
                if paragraphScope.contains(name) { return }
                index -= 1
            }
        }

        func closeOpenListItem() {
            var index = stack.count - 1
            while index > 0 {
                let name = stack[index].name
                if name == "li" {
                    stack.removeSubrange(index...)
                    return
                }
                if name == "ul" || name == "ol" { return }
                index -= 1
            }
        }

        while let token = tokenizer.next() {
            switch token {
            case .text(let text):
                if !text.isEmpty { current().children.append(.text(text)) }
            case .start(let name, let attributes):
                if closesParagraph.contains(name) { closeOpenParagraph() }
                if name == "li" { closeOpenListItem() }
                let node = HTMLNode(name: name, attributes: attributes)
                current().children.append(.element(node))
                if !voidElements.contains(name), stack.count < maxDepth {
                    stack.append(node)
                }
            case .end(let name):
                if name == "br" {
                    current().children.append(.element(HTMLNode(name: "br")))
                    continue
                }
                var index = stack.count - 1
                while index > 0, stack[index].name != name { index -= 1 }
                if index > 0 { stack.removeSubrange(index...) }
            }
        }
        return root
    }
}

// MARK: - Tokenizer

enum HTMLToken {
    case text(String)
    case start(name: String, attributes: [String: String])
    case end(name: String)
}

/// A forgiving HTML tokenizer. It never fails: whatever it cannot understand is either
/// treated as text or skipped.
struct HTMLTokenizer {
    private let bytes: [UInt8]
    private var pos = 0
    private var pending: [HTMLToken] = []

    init(_ html: String) {
        bytes = Array(html.utf8)
    }

    private static let lt = UInt8(ascii: "<")
    private static let gt = UInt8(ascii: ">")

    private static func isLetter(_ b: UInt8) -> Bool {
        (b >= 65 && b <= 90) || (b >= 97 && b <= 122)
    }

    private static func isSpace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0C || b == 0x0D
    }

    private static func isNameByte(_ b: UInt8) -> Bool {
        isLetter(b) || (b >= 48 && b <= 57) || b == UInt8(ascii: "-") || b == UInt8(ascii: "_") || b == UInt8(ascii: ":")
    }

    /// Does markup (rather than a literal "<") start at `index`?
    private func isMarkupStart(_ index: Int) -> Bool {
        guard index + 1 < bytes.count, bytes[index] == Self.lt else { return false }
        let next = bytes[index + 1]
        if Self.isLetter(next) || next == UInt8(ascii: "!") || next == UInt8(ascii: "?") { return true }
        if next == UInt8(ascii: "/") { return index + 2 < bytes.count && Self.isLetter(bytes[index + 2]) }
        return false
    }

    mutating func next() -> HTMLToken? {
        while true {
            if !pending.isEmpty { return pending.removeFirst() }
            guard pos < bytes.count else { return nil }
            if isMarkupStart(pos) {
                if let token = readMarkup() { return token }
                continue
            }
            // Text up to the next real markup.
            let start = pos
            pos += 1
            while pos < bytes.count, !isMarkupStart(pos) { pos += 1 }
            return .text(HTMLEntities.decode(bytes[start..<pos]))
        }
    }

    private func find(_ needle: [UInt8], from start: Int) -> Int? {
        guard !needle.isEmpty, bytes.count >= needle.count, start <= bytes.count - needle.count else { return nil }
        var i = start
        let last = bytes.count - needle.count
        while i <= last {
            if bytes[i] == needle[0] {
                var matched = true
                for j in 1..<needle.count where bytes[i + j] != needle[j] {
                    matched = false
                    break
                }
                if matched { return i }
            }
            i += 1
        }
        return nil
    }

    /// Case-insensitive search for `</name`.
    private func findEndTag(_ name: String, from start: Int) -> Int? {
        let lower = Array(name.utf8)
        var i = start
        while i + 2 + lower.count <= bytes.count {
            if bytes[i] == Self.lt, bytes[i + 1] == UInt8(ascii: "/") {
                var matched = true
                for (j, expected) in lower.enumerated() {
                    let b = bytes[i + 2 + j]
                    let folded = (b >= 65 && b <= 90) ? b + 32 : b
                    if folded != expected {
                        matched = false
                        break
                    }
                }
                if matched { return i }
            }
            i += 1
        }
        return nil
    }

    private mutating func readMarkup() -> HTMLToken? {
        let next = bytes[pos + 1]
        if next == UInt8(ascii: "!") {
            if pos + 3 < bytes.count, bytes[pos + 2] == UInt8(ascii: "-"), bytes[pos + 3] == UInt8(ascii: "-") {
                // Comment.
                if let end = find(Array("-->".utf8), from: pos + 4) { pos = end + 3 } else { pos = bytes.count }
                return nil
            }
            let cdata = Array("<![CDATA[".utf8)
            if pos + cdata.count <= bytes.count, Array(bytes[pos..<(pos + cdata.count)]) == cdata {
                let start = pos + cdata.count
                let end = find(Array("]]>".utf8), from: start) ?? bytes.count
                pos = min(bytes.count, end + 3)
                return .text(String(decoding: bytes[start..<end], as: UTF8.self))
            }
            skipPast(Self.gt)
            return nil
        }
        if next == UInt8(ascii: "?") {
            skipPast(Self.gt)
            return nil
        }
        if next == UInt8(ascii: "/") {
            pos += 2
            let name = readName()
            skipPast(Self.gt)
            return .end(name: name)
        }
        pos += 1
        let name = readName()
        let attributes = readAttributes()
        if name == "script" || name == "style" {
            // Raw text: nothing inside is markup. Skip to the matching end tag.
            if let end = findEndTag(name, from: pos) {
                pos = end
                skipPast(Self.gt)
            } else {
                pos = bytes.count
            }
            return nil
        }
        return .start(name: name, attributes: attributes)
    }

    private mutating func skipPast(_ byte: UInt8) {
        while pos < bytes.count, bytes[pos] != byte { pos += 1 }
        if pos < bytes.count { pos += 1 }
    }

    private mutating func readName() -> String {
        let start = pos
        while pos < bytes.count, Self.isNameByte(bytes[pos]) { pos += 1 }
        return String(decoding: bytes[start..<pos], as: UTF8.self).lowercased()
    }

    /// Reads attributes up to and including the closing ">" (or the end of input).
    private mutating func readAttributes() -> [String: String] {
        var attributes: [String: String] = [:]
        while pos < bytes.count {
            let b = bytes[pos]
            if b == Self.gt {
                pos += 1
                return attributes
            }
            if Self.isSpace(b) || b == UInt8(ascii: "/") {
                pos += 1
                continue
            }
            // Attribute name.
            let nameStart = pos
            while pos < bytes.count {
                let c = bytes[pos]
                if Self.isSpace(c) || c == UInt8(ascii: "=") || c == Self.gt || c == UInt8(ascii: "/") { break }
                pos += 1
            }
            if pos == nameStart {
                pos += 1  // a stray "=": skip it
                continue
            }
            let name = String(decoding: bytes[nameStart..<pos], as: UTF8.self).lowercased()
            while pos < bytes.count, Self.isSpace(bytes[pos]) { pos += 1 }
            var value = ""
            if pos < bytes.count, bytes[pos] == UInt8(ascii: "=") {
                pos += 1
                while pos < bytes.count, Self.isSpace(bytes[pos]) { pos += 1 }
                if pos < bytes.count, bytes[pos] == UInt8(ascii: "\"") || bytes[pos] == UInt8(ascii: "'") {
                    let quote = bytes[pos]
                    pos += 1
                    let valueStart = pos
                    while pos < bytes.count, bytes[pos] != quote { pos += 1 }
                    value = HTMLEntities.decode(bytes[valueStart..<pos])
                    if pos < bytes.count { pos += 1 }
                } else {
                    let valueStart = pos
                    while pos < bytes.count, !Self.isSpace(bytes[pos]), bytes[pos] != Self.gt { pos += 1 }
                    value = HTMLEntities.decode(bytes[valueStart..<pos])
                }
            }
            if attributes[name] == nil { attributes[name] = value }
        }
        return attributes
    }
}

// MARK: - Entities

enum HTMLEntities {
    static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}", "zwnj": "\u{200C}", "zwj": "\u{200D}",
        "shy": "\u{00AD}", "ndash": "\u{2013}", "mdash": "\u{2014}", "horbar": "\u{2015}",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "sbquo": "\u{201A}", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
        "bdquo": "\u{201E}", "laquo": "\u{00AB}", "raquo": "\u{00BB}", "lsaquo": "\u{2039}", "rsaquo": "\u{203A}",
        "hellip": "\u{2026}", "bull": "\u{2022}", "middot": "\u{00B7}", "dagger": "\u{2020}", "Dagger": "\u{2021}",
        "prime": "\u{2032}", "Prime": "\u{2033}", "copy": "\u{00A9}", "reg": "\u{00AE}", "trade": "\u{2122}",
        "deg": "\u{00B0}", "plusmn": "\u{00B1}", "times": "\u{00D7}", "divide": "\u{00F7}", "minus": "\u{2212}",
        "frac12": "\u{00BD}", "frac14": "\u{00BC}", "frac34": "\u{00BE}", "sup1": "\u{00B9}", "sup2": "\u{00B2}",
        "sup3": "\u{00B3}", "micro": "\u{00B5}", "para": "\u{00B6}", "sect": "\u{00A7}", "cent": "\u{00A2}",
        "pound": "\u{00A3}", "euro": "\u{20AC}", "yen": "\u{00A5}", "curren": "\u{00A4}", "iexcl": "\u{00A1}",
        "iquest": "\u{00BF}", "ordf": "\u{00AA}", "ordm": "\u{00BA}", "not": "\u{00AC}", "macr": "\u{00AF}",
        "acute": "\u{00B4}", "cedil": "\u{00B8}", "uml": "\u{00A8}", "brvbar": "\u{00A6}",
        "larr": "\u{2190}", "uarr": "\u{2191}", "rarr": "\u{2192}", "darr": "\u{2193}", "harr": "\u{2194}",
        "rArr": "\u{21D2}", "lArr": "\u{21D0}", "hArr": "\u{21D4}", "ne": "\u{2260}", "le": "\u{2264}",
        "ge": "\u{2265}", "asymp": "\u{2248}", "infin": "\u{221E}", "permil": "\u{2030}", "loz": "\u{25CA}",
        "spades": "\u{2660}", "clubs": "\u{2663}", "hearts": "\u{2665}", "diams": "\u{2666}", "check": "\u{2713}",
        "Agrave": "\u{00C0}", "Aacute": "\u{00C1}", "Acirc": "\u{00C2}", "Atilde": "\u{00C3}", "Auml": "\u{00C4}",
        "Aring": "\u{00C5}", "AElig": "\u{00C6}", "Ccedil": "\u{00C7}", "Egrave": "\u{00C8}", "Eacute": "\u{00C9}",
        "Ecirc": "\u{00CA}", "Euml": "\u{00CB}", "Igrave": "\u{00CC}", "Iacute": "\u{00CD}", "Icirc": "\u{00CE}",
        "Iuml": "\u{00CF}", "ETH": "\u{00D0}", "Ntilde": "\u{00D1}", "Ograve": "\u{00D2}", "Oacute": "\u{00D3}",
        "Ocirc": "\u{00D4}", "Otilde": "\u{00D5}", "Ouml": "\u{00D6}", "Oslash": "\u{00D8}", "Ugrave": "\u{00D9}",
        "Uacute": "\u{00DA}", "Ucirc": "\u{00DB}", "Uuml": "\u{00DC}", "Yacute": "\u{00DD}", "THORN": "\u{00DE}",
        "szlig": "\u{00DF}", "agrave": "\u{00E0}", "aacute": "\u{00E1}", "acirc": "\u{00E2}", "atilde": "\u{00E3}",
        "auml": "\u{00E4}", "aring": "\u{00E5}", "aelig": "\u{00E6}", "ccedil": "\u{00E7}", "egrave": "\u{00E8}",
        "eacute": "\u{00E9}", "ecirc": "\u{00EA}", "euml": "\u{00EB}", "igrave": "\u{00EC}", "iacute": "\u{00ED}",
        "icirc": "\u{00EE}", "iuml": "\u{00EF}", "eth": "\u{00F0}", "ntilde": "\u{00F1}", "ograve": "\u{00F2}",
        "oacute": "\u{00F3}", "ocirc": "\u{00F4}", "otilde": "\u{00F5}", "ouml": "\u{00F6}", "oslash": "\u{00F8}",
        "ugrave": "\u{00F9}", "uacute": "\u{00FA}", "ucirc": "\u{00FB}", "uuml": "\u{00FC}", "yacute": "\u{00FD}",
        "thorn": "\u{00FE}", "yuml": "\u{00FF}", "OElig": "\u{0152}", "oelig": "\u{0153}", "Scaron": "\u{0160}",
        "scaron": "\u{0161}", "Yuml": "\u{0178}", "fnof": "\u{0192}", "circ": "\u{02C6}", "tilde": "\u{02DC}",
        "alpha": "\u{03B1}", "beta": "\u{03B2}", "gamma": "\u{03B3}", "delta": "\u{03B4}", "epsilon": "\u{03B5}",
        "lambda": "\u{03BB}", "mu": "\u{03BC}", "pi": "\u{03C0}", "sigma": "\u{03C3}", "tau": "\u{03C4}",
        "phi": "\u{03C6}", "omega": "\u{03C9}", "Delta": "\u{0394}", "Sigma": "\u{03A3}", "Omega": "\u{03A9}",
    ]

    /// Decode character references. Unknown or malformed references are kept as literal text.
    static func decode(_ slice: ArraySlice<UInt8>) -> String {
        guard slice.contains(UInt8(ascii: "&")) else { return String(decoding: slice, as: UTF8.self) }
        let bytes = Array(slice)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            guard b == UInt8(ascii: "&") else {
                out.append(b)
                i += 1
                continue
            }
            // Find the terminating ";" within a sane distance.
            var j = i + 1
            let limit = min(bytes.count, i + 34)
            while j < limit, bytes[j] != UInt8(ascii: ";"), bytes[j] != UInt8(ascii: "&"), bytes[j] > 0x20 { j += 1 }
            guard j < limit, bytes[j] == UInt8(ascii: ";"), j > i + 1 else {
                out.append(b)
                i += 1
                continue
            }
            let body = String(decoding: bytes[(i + 1)..<j], as: UTF8.self)
            if let replacement = resolve(body) {
                out.append(contentsOf: Array(replacement.utf8))
                i = j + 1
            } else {
                out.append(b)
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func resolve(_ body: String) -> String? {
        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let value: UInt32?
            if digits.hasPrefix("x") || digits.hasPrefix("X") {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits, radix: 10)
            }
            guard let value else { return nil }
            // Windows-1252 leftovers that browsers map for &#128;–&#159;.
            let remapped: UInt32
            switch value {
            case 0x85: remapped = 0x2026
            case 0x91: remapped = 0x2018
            case 0x92: remapped = 0x2019
            case 0x93: remapped = 0x201C
            case 0x94: remapped = 0x201D
            case 0x96: remapped = 0x2013
            case 0x97: remapped = 0x2014
            default: remapped = value
            }
            guard let scalar = Unicode.Scalar(remapped), HTMLCleaner.isValidXMLScalar(scalar) else { return "\u{FFFD}" }
            return String(Character(scalar))
        }
        return named[body]
    }
}
