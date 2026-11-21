import Foundation

/// Three sample articles (placeholder text with headings, quotes and lists) for testing the
/// device without any login. Fixed URLs and dates, so their ids and bytes never change.
public enum DemoArticles {
    private static let filler = [
        "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat.",
        "Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum.",
        "Curabitur pretium tincidunt lacus. Nulla gravida orci a odio. Nullam varius, turpis et commodo pharetra, est eros bibendum elit, nec luctus magna felis sollicitudin mauris. Integer in mauris eu nibh euismod gravida.",
        "Pellentesque habitant morbi tristique senectus et netus et malesuada fames ac turpis egestas. Vestibulum tortor quam, feugiat vitae, ultricies eget, tempor sit amet, ante. Donec eu libero sit amet quam egestas semper.",
        "Aenean ultricies mi vitae est. Mauris placerat eleifend leo. Quisque sit amet est et sapien ullamcorper pharetra. Vestibulum erat wisi, condimentum sed, commodo vitae, ornare sit amet, wisi.",
    ]

    private static func paragraphs(_ count: Int, offset: Int) -> String {
        (0..<count).map { "<p>\(filler[($0 + offset) % filler.count])</p>" }.joined(separator: "\n")
    }

    private static func html(_ index: Int) -> String {
        switch index {
        case 0:
            return """
                <p>This is a <strong>Paperboy test article</strong>. If you can read it on the device, the whole chain works: \
                packaging, Bluetooth transfer, storage &amp; the reader.</p>
                \(paragraphs(3, offset: 0))
                <h2>A second-level heading</h2>
                \(paragraphs(2, offset: 3))
                <blockquote><p>A quotation set apart from the text: <em>“Reading starts on a whim, with no waiting on a sync.”</em></p></blockquote>
                \(paragraphs(2, offset: 1))
                <h3>A list of things</h3>
                <ul><li>First item, short.</li><li>Second item, with <em>emphasis</em> and <strong>strength</strong>.</li>\
                <li>Third item, which is long enough to wrap onto a second line on a small e-ink screen, probably a third.</li></ul>
                \(paragraphs(4, offset: 2))
                """
        case 1:
            return """
                <p><em>A longer piece, to exercise the flow-control window: it is several times 8192 bytes.</em></p>
                \(paragraphs(45, offset: 1))
                <h2>Numbered steps</h2>
                <ol><li>Turn the device on.</li><li>Wait for the phone to notice.</li><li>Read.</li></ol>
                \(paragraphs(50, offset: 2))
                <hr/>
                <h2>Typography</h2>
                <p>Curly quotes “like these”, an em dash — like that, an ellipsis… and accents: café, naïve, Zürich, São Paulo. \
                Symbols: © ® ™ € £ ½ × °. An ampersand &amp; a less-than &lt; sign.</p>
                <pre>preformatted text
                  keeps   its   spacing</pre>
                \(paragraphs(50, offset: 4))
                """
        default:
            return """
                <p>A short one.</p>
                <blockquote><p>Brevity is the soul of wit.</p></blockquote>
                \(paragraphs(1, offset: 4))
                """
        }
    }

    public static let articles: [Article] = {
        let titles = ["Paperboy Test: Hello, Reader", "Paperboy Test: The Long One", "Paperboy Test: Short & Sweet"]
        let authors = ["Ada Example", "Grace Sample & Alan Placeholder", "Edsger Demo"]
        // 15 November 2026, 12:00 UTC, one hour apart.
        let base = Date(timeIntervalSince1970: 1_794_744_000)
        return (0..<3).map { index in
            Article(
                url: "https://paperboy.invalid/demo/\(index + 1)",
                source: "Paperboy Demo",
                title: titles[index],
                author: authors[index],
                date: base.addingTimeInterval(Double(index) * 3600),
                bodyXHTML: HTMLCleaner.clean(html(index)))
        }
    }()
}

extension Article {
    /// The article as the session offers it to the device.
    public var syncItem: SyncItem {
        SyncItem(id: id, time: date, source: source, title: title, author: author)
    }
}
