import Foundation

public enum EconomistDiscovery {
    public static let frontPageURL = "https://www.economist.com/"

    public static func isPublisherHost(_ host: String) -> Bool {
        switch host.lowercased() {
        case "economist.com", "www.economist.com": true
        default: false
        }
    }

    /// Query-free identity for a story or an explicitly shared editorial feature.
    public static func storyURL(_ url: URL) -> URL? {
        canonicalStoryURL(url, datedOnly: false)
    }

    /// Use for a user-initiated load. Keep the gift token opaque, including its percent encoding.
    public static func loadingURL(for url: URL) -> URL? {
        guard let canonical = storyURL(url) else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: true)?.percentEncodedQueryItems
        guard let gift = items?.first(where: { $0.name == "giftId" && $0.value?.isEmpty == false }),
              var components = URLComponents(url: canonical, resolvingAgainstBaseURL: false) else { return canonical }
        components.percentEncodedQueryItems = [gift]
        return components.url
    }

    /// Accept either the rendered homepage or a fragment of links collected from its main region.
    public static func storyLinks(in html: String) -> [String] {
        let root = HTMLTreeBuilder.build(html, maxDepth: 64)
        var anchors: [(href: String, inMain: Bool)] = []
        var requiresMain = false
        func visit(_ node: HTMLNode, inMain: Bool) {
            let role = node.attributes["role"]?.lowercased() ?? ""
            guard !excludedElements.contains(node.name), !excludedRoles.contains(role),
                  node.attributes["hidden"] == nil, node.attributes["aria-hidden"]?.lowercased() != "true" else { return }
            let isMain = inMain || node.name == "main" || role == "main"
            if isMain || node.name == "html" || node.name == "body" { requiresMain = true }
            if node.name == "a", let href = node.attributes["href"] {
                anchors.append((href, isMain))
            }
            for case .element(let child) in node.children { visit(child, inMain: isMain) }
        }
        visit(root, inMain: false)

        let base = URL(string: frontPageURL)
        var seen = Set<String>()
        return anchors.compactMap { anchor in
            guard !requiresMain || anchor.inMain,
                  let url = URL(string: anchor.href, relativeTo: base),
                  let story = canonicalStoryURL(url, datedOnly: true)?.absoluteString,
                  seen.insert(story).inserted else { return nil }
            return story
        }
    }

    private static let excludedElements: Set<String> = [
        "aside", "footer", "head", "iframe", "nav", "noscript", "svg", "template", "textarea", "title",
    ]
    private static let excludedRoles: Set<String> = ["banner", "complementary", "contentinfo", "dialog", "navigation"]

    private static let sections: Set<Substring> = [
        "1843", "asia", "books-and-arts", "briefing", "britain", "business", "by-invitation", "china", "christmas-specials",
        "culture", "economic-and-financial-indicators", "essay", "europe", "finance-and-economics",
        "graphic-detail", "in-brief", "international", "leaders", "letters", "middle-east-and-africa",
        "obituary", "open-future", "science-and-technology", "special-report", "technology-quarterly", "the-americas",
        "the-economist-explains", "the-economist-reads", "the-world-ahead", "the-world-if",
        "the-world-this-week", "united-states",
    ]

    private static func canonicalStoryURL(_ url: URL, datedOnly: Bool) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              components.scheme?.lowercased() == "https",
              let host = components.percentEncodedHost, isPublisherHost(host),
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443 else { return nil }

        let encoded = components.percentEncodedPath
        guard encoded.range(of: "%2f", options: .caseInsensitive) == nil,
              var path = encoded.removingPercentEncoding else { return nil }
        if path.hasSuffix("/") { path.removeLast() }
        guard isDatedStory(path) || (!datedOnly && isSharedFeature(path)) else { return nil }
        components.scheme = "https"
        components.host = "www.economist.com"
        components.port = nil
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func isDatedStory(_ path: String) -> Bool {
        guard let match = path.wholeMatch(of: #//(?:interactive/)?([a-z0-9-]+)/([0-9]{4})/([0-9]{2})/([0-9]{2})/[a-z0-9]+(?:-[a-z0-9]+)*/#),
              sections.contains(match.1), let year = Int(match.2), let month = Int(match.3), let day = Int(match.4) else { return false }
        return DateComponents(year: year, month: month, day: day).isValidDate(in: Calendar(identifier: .gregorian))
    }

    private static func isSharedFeature(_ path: String) -> Bool {
        // Legacy article IDs and undated editorial slugs are useful for direct shares.
        if path.wholeMatch(of: #//node/[0-9]+/#) != nil { return true }
        if let legacy = path.wholeMatch(of: #//news/([a-z-]+)/[0-9]+-[a-z0-9]+(?:-[a-z0-9]+)*/#) {
            return sections.contains(legacy.1) || legacy.1 == "americas"
        }

        let parts = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[1].wholeMatch(of: #/[a-z0-9]+(?:-[a-z0-9]+)+/#) != nil,
              parts[1].contains(where: \.isLetter), !sections.contains(parts[1]) else { return false }
        if parts[0] == "interactive" {
            // Some interactive projects have subpages, e.g. us-2024-election/prediction-model/president.
            return parts.dropFirst(2).allSatisfy { $0.wholeMatch(of: #/[a-z][a-z0-9]*(?:-[a-z0-9]+)*/#) != nil }
        }
        return parts.count == 2 && sections.contains(parts[0])
    }
}
