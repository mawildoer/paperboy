import Foundation

/// Token matching over metadata only. Every query token must match a field.
public enum MetadataSearch {
    public static func score(_ query: String, title: String, author: String, source: String) -> Int? {
        let terms = Array(words(String(query.prefix(256))).prefix(32))
        guard !terms.isEmpty else { return 0 }
        let fields = [title, author, source].map(words)
        let candidates = fields.flatMap { $0 } + fields.map { $0.compactMap(\.first).map(String.init).joined() }
        var total = 0
        for term in terms {
            let best = candidates.map { match(term, $0) }.max() ?? 0
            guard best > 0 else { return nil }
            total += best
        }
        return total
    }

    private static func words(_ text: String) -> [String] {
        String(text.prefix(4096)).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    private static func match(_ query: String, _ word: String) -> Int {
        if query == word { return 100 }
        if word.hasPrefix(query) { return 85 }
        if query.count >= 3, word.contains(query) { return 70 }
        let limit = query.count >= 6 ? 2 : query.count >= 3 ? 1 : 0
        guard limit > 0, abs(query.count - word.count) <= limit else { return 0 }
        let a = Array(query), b = Array(word)
        var previous = Array(0...b.count)
        var beforePrevious = previous
        for i in 1...a.count {
            var row = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                row[j] = min(row[j - 1] + 1, previous[j] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    row[j] = min(row[j], beforePrevious[j - 2] + 1)
                }
            }
            beforePrevious = previous
            previous = row
        }
        return previous[b.count] <= limit ? 60 - previous[b.count] * 10 : 0
    }
}
