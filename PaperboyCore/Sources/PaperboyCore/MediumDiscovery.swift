import Foundation

public enum MediumError: Error, Sendable, CustomStringConvertible, LocalizedError {
    case accessRequired

    public var description: String {
        "Medium is showing a preview. Sign in with an account that can read this story, then try again."
    }
    public var errorDescription: String? { description }
}

/// Discovery from Medium's signed-in Following page; extraction stays on the device.
public enum MediumDiscovery {
    public static let loginURL = URL(string: "https://medium.com/m/signin")
    /// A session hint only. Access to each member story is checked separately.
    public static let sessionCookieNames: Set<String> = ["sid"]

    public static func isMediumHost(_ host: String) -> Bool {
        let host = host.lowercased()
        return host == "medium.com" || host.hasSuffix(".medium.com")
    }

    public static let followingURL = "https://medium.com/me/following"

    /// Links from the rendered Following page, in page order. No private subscription API.
    public static func storyLinks(in html: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"href\s*=\s*["']([^"']+)["']"#, options: [.caseInsensitive]) else { return [] }
        let text = html as NSString
        var seen = Set<String>()
        return regex.matches(in: html, range: NSRange(location: 0, length: text.length)).compactMap { match in
            let raw = HTMLCleaner.plainText(text.substring(with: match.range(at: 1)))
            guard let url = URL(string: raw, relativeTo: URL(string: followingURL))?.absoluteURL,
                  isStoryURL(url.absoluteString, customHosts: [url.host ?? ""]) else { return nil }
            let canonical = URLCanonicalizer.canonicalize(url.absoluteString)
            return seen.insert(canonical).inserted ? canonical : nil
        }
    }

    public static func isStoryURL(_ text: String, customHosts: [String] = []) -> Bool {
        guard let c = URLComponents(string: text), c.scheme == "https", c.user == nil, c.password == nil,
              let host = c.host?.lowercased(), isMediumHost(host) || customHosts.contains(host) else { return false }
        return isStorySlug(c.path.split(separator: "/").last.map(String.init) ?? "")
    }

    private static func isStorySlug(_ slug: String) -> Bool {
        let id = slug.split(separator: "-").last.map(String.init) ?? ""
        return id.count == 12 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

}
