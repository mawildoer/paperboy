import Foundation
import PaperboyCore

/// User settings, stored as JSON in UserDefaults. No credentials live here: sessions are
/// cookies in the system cookie stores.
struct AppSettings: Codable, Equatable, Sendable {
    // Substack
    var substackEnabled = true
    /// Discover posts from the reader inbox on substack.com.
    var substackUseInbox = true
    /// Favourite publications: read from their own archive, fetched before the inbox and not
    /// counted against `substackMaxPerFetch`. A host ("www.slowboring.com", "x.substack.com") or
    /// a bare Substack subdomain.
    var substackPublications: [String] = ["www.slowboring.com"]
    /// Put new posts from favourite authors on the reader without being asked.
    var autoLoadFavourites = false
    /// Set once the starting favourite has been added to settings saved by an earlier build.
    var favouritesSeeded = true
    /// Most posts fetched in one run.
    var substackMaxPerFetch = 15

    // NYT
    var nytEnabled = true
    /// RSS feeds (rss.nytimes.com) or section page URLs.
    var nytFeeds: [String] = NYTDiscovery.defaultFeeds
    /// Most articles fetched per 24 hours (the newest ones win).
    var nytDailyCap = 25

    // How long an article stays in the phone's list (what is on the reader is chosen per article).
    var unreadDays = 14.0
    var readDays = 2.0

    /// Longest the connect-time fetch may take before the sync session starts.
    var connectFetchSeconds = 5.0

    var retention: RetentionPolicy {
        RetentionPolicy(unreadDays: unreadDays, readDays: readDays)
    }

    private static let key = "paperboy.settings.v1"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    // Decoding tolerates settings saved by an older build that lacked some fields.
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        substackEnabled = try c.decodeIfPresent(Bool.self, forKey: .substackEnabled) ?? d.substackEnabled
        substackUseInbox = try c.decodeIfPresent(Bool.self, forKey: .substackUseInbox) ?? d.substackUseInbox
        substackPublications = try c.decodeIfPresent([String].self, forKey: .substackPublications) ?? d.substackPublications
        substackMaxPerFetch = try c.decodeIfPresent(Int.self, forKey: .substackMaxPerFetch) ?? d.substackMaxPerFetch
        if !(try c.decodeIfPresent(Bool.self, forKey: .favouritesSeeded) ?? false) {
            for host in d.substackPublications where !substackPublications.contains(host) {
                substackPublications.append(host)
            }
        }
        favouritesSeeded = true
        autoLoadFavourites = try c.decodeIfPresent(Bool.self, forKey: .autoLoadFavourites) ?? d.autoLoadFavourites
        nytEnabled = try c.decodeIfPresent(Bool.self, forKey: .nytEnabled) ?? d.nytEnabled
        nytFeeds = try c.decodeIfPresent([String].self, forKey: .nytFeeds) ?? d.nytFeeds
        nytDailyCap = try c.decodeIfPresent(Int.self, forKey: .nytDailyCap) ?? d.nytDailyCap
        unreadDays = try c.decodeIfPresent(Double.self, forKey: .unreadDays) ?? d.unreadDays
        readDays = try c.decodeIfPresent(Double.self, forKey: .readDays) ?? d.readDays
        connectFetchSeconds = try c.decodeIfPresent(Double.self, forKey: .connectFetchSeconds) ?? d.connectFetchSeconds
    }
}

/// A small in-memory log shown in the app, for debugging on the phone.
/// Callers must never pass cookie values or other credentials.
@MainActor
final class AppLog: ObservableObject {
    static let shared = AppLog()
    @Published private(set) var lines: [String] = []

    func add(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let line = "\(formatter.string(from: Date())) \(message)"
        lines.append(line)
        if lines.count > 400 { lines.removeFirst(lines.count - 400) }
        appendToFile(line)
    }

    /// Documents/paperboy.log, so the log can be copied off the phone while debugging.
    /// Never holds cookie values: callers log outcomes, not credentials.
    private func appendToFile(_ line: String) {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let data = (line + "\n").data(using: .utf8) else { return }
        let url = dir.appendingPathComponent("paperboy.log")
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 1_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    /// For callbacks that arrive off the main actor.
    nonisolated static func post(_ message: String) {
        Task { @MainActor in shared.add(message) }
    }
}

/// What one fetch run did.
struct FetchSummary: Sendable {
    var added = 0
    var failed = 0
    var notes: [String] = []

    mutating func merge(_ other: FetchSummary) {
        added += other.added
        failed += other.failed
        notes += other.notes
    }
}
