import Foundation

/// Handles labels that survived conversion to Paperboy's small XHTML vocabulary.
enum ArticleAdControls {
    // Match whole generated paragraphs, allowing the emphasis and line breaks the cleaner emits.
    // Preserve quotations and code examples verbatim.
    private static let spacing = #"(?:\s|</?(?:em|i|b|strong)>|<br\s*/?>)"#
    private static let paragraphs = try! NSRegularExpression(pattern:
        #"(?is)(<(blockquote|pre)\b[^>]*>.*?</\2>)|<p>\#(spacing)*(?:advertisement(?:\#(spacing)+skip\#(spacing)+advertisement)?|skip\#(spacing)+(?:this\#(spacing)+)?(?:ad|advertisement)|continue\s+reading\s+(?:after|below)\s+(?:the\s+)?advertisement)\#(spacing)*</p>"#)

    // Some reader-mode versions joined both controls and the first sentence in one paragraph.
    private static let joinedOpening = try! NSRegularExpression(pattern:
        #"(?i)^(\s*<p>\s*)advertisement\s+skip\s+advertisement\s+"#)

    static func clean(_ body: String) -> String {
        guard body.localizedCaseInsensitiveContains("ad") else { return body }
        let range = NSRange(body.startIndex..., in: body)
        let stripped = paragraphs.stringByReplacingMatches(in: body, range: range, withTemplate: "$1")
        return joinedOpening.stringByReplacingMatches(in: stripped, range: NSRange(stripped.startIndex..., in: stripped), withTemplate: "$1")
    }

    static func mayStartWithControl(_ preview: String) -> Bool {
        let lower = preview.lowercased()
        return lower.hasPrefix("advertisement") || lower.hasPrefix("skip ad") || lower.hasPrefix("skip this ad") ||
            lower.hasPrefix("continue reading below") || lower.hasPrefix("continue reading after")
    }
}
