import Foundation

/// Whether an article belongs on the reader. Chosen per article in the phone app.
public enum LoadState: String, Codable, Sendable, CaseIterable {
    /// Stays on the phone only.
    case off
    /// On the reader until it has been read; taken off at the next sync after that.
    case load
    /// On the reader until unlocked, read or not.
    case lock

    /// The order one tap steps through: off, load, lock, off.
    public var next: LoadState {
        switch self {
        case .off: return .load
        case .load: return .lock
        case .lock: return .off
        }
    }
}

public struct StoredArticle: Codable, Sendable, Equatable, Identifiable {
    public var id: ArticleID
    public var url: String
    public var source: String
    public var title: String
    public var author: String
    /// Publication date.
    public var date: Date
    public var fetchedAt: Date
    /// Opened on the device (learned from the device's LIST) or marked in the app.
    public var read: Bool
    /// When the phone first learned the article was read; the 2-day clock starts here.
    public var readAt: Date?
    /// The device had this article at the end of the last sync.
    public var onDevice: Bool
    /// Set when retention retires the article. The EPUB is gone; the entry stays as a tombstone
    /// so the device copy can be deleted and the article is not fetched again.
    public var retiredAt: Date?
    public var size: Int
    public var crc32: UInt32
    public var load: LoadState
    /// The first lines of the text, for the list in the app.
    public var preview: String
    public var bumpedAt: Date?
    public var pendingBump: UInt32?

    public var isRetired: Bool { retiredAt != nil }
    /// Should the reader hold this article now? A read article stays only while locked.
    public var wantedOnDevice: Bool {
        !isRetired && (load == .lock || (load == .load && !read))
    }

    public init(
        id: ArticleID, url: String, source: String, title: String, author: String, date: Date, fetchedAt: Date,
        read: Bool, readAt: Date?, onDevice: Bool, retiredAt: Date?, size: Int, crc32: UInt32,
        load: LoadState = .off, preview: String = ""
    ) {
        self.id = id
        self.url = url
        self.source = source
        self.title = title
        self.author = author
        self.date = date
        self.fetchedAt = fetchedAt
        self.read = read
        self.readAt = readAt
        self.onDevice = onDevice
        self.retiredAt = retiredAt
        self.size = size
        self.crc32 = crc32
        self.load = load
        self.preview = preview
        self.bumpedAt = nil
        self.pendingBump = nil
    }

    // An index written before load states existed has neither field: those articles are off.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ArticleID.self, forKey: .id)
        url = try c.decode(String.self, forKey: .url)
        source = try c.decode(String.self, forKey: .source)
        title = try c.decode(String.self, forKey: .title)
        author = try c.decode(String.self, forKey: .author)
        date = try c.decode(Date.self, forKey: .date)
        fetchedAt = try c.decode(Date.self, forKey: .fetchedAt)
        read = try c.decode(Bool.self, forKey: .read)
        readAt = try c.decodeIfPresent(Date.self, forKey: .readAt)
        onDevice = try c.decode(Bool.self, forKey: .onDevice)
        retiredAt = try c.decodeIfPresent(Date.self, forKey: .retiredAt)
        size = try c.decode(Int.self, forKey: .size)
        crc32 = try c.decode(UInt32.self, forKey: .crc32)
        load = try c.decodeIfPresent(LoadState.self, forKey: .load) ?? .off
        bumpedAt = try c.decodeIfPresent(Date.self, forKey: .bumpedAt)
        pendingBump = try c.decodeIfPresent(UInt32.self, forKey: .pendingBump)
        preview = try c.decodeIfPresent(String.self, forKey: .preview) ?? ""
    }
}

/// How long an article stays in the phone's list. What is on the reader is decided by each
/// article's `LoadState`, not by this; an article the reader should hold is never retired.
public struct RetentionPolicy: Codable, Sendable, Equatable {
    /// Unread articles are retired this long after they were fetched.
    public var unreadDays: Double
    /// Read articles are retired this long after the phone learned they were read.
    public var readDays: Double
    /// Tombstones of retired articles are forgotten after this long (once off the device).
    public var tombstoneDays: Double

    public init(unreadDays: Double = 14, readDays: Double = 2, tombstoneDays: Double = 60) {
        self.unreadDays = unreadDays
        self.readDays = readDays
        self.tombstoneDays = tombstoneDays
    }

    public func shouldRetire(_ article: StoredArticle, now: Date) -> Bool {
        if article.wantedOnDevice { return false }
        let day: TimeInterval = 86_400
        if article.read {
            let since = article.readAt ?? article.fetchedAt
            return now.timeIntervalSince(since) > readDays * day
        }
        return now.timeIntervalSince(article.fetchedAt) > unreadDays * day
    }
}

public enum ArticleStoreError: Error, Sendable, Equatable {
    case unknownArticle(ArticleID)
    case missingFile(ArticleID)
}

/// The phone's library: `index.json` plus one `<id>.epub` per article in a directory.
public actor ArticleStore {
    public let directory: URL
    private var articles: [ArticleID: StoredArticle] = [:]

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let index = directory.appendingPathComponent("index.json")
        if let data = try? Data(contentsOf: index) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            // A corrupt index is not fatal: start empty, the articles get fetched again.
            if let list = try? decoder.decode([StoredArticle].self, from: data) {
                for article in list { articles[article.id] = article }
            }
        }
    }

    public func fileURL(for id: ArticleID) -> URL {
        directory.appendingPathComponent("\(id.hex).epub")
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let list = articles.values.sorted { $0.id.hex < $1.id.hex }
        try encoder.encode(list).write(to: indexURL, options: .atomic)
    }

    // MARK: Reading

    /// Live (not retired) articles, newest first.
    public func all() -> [StoredArticle] {
        articles.values.filter { !$0.isRetired }.sorted { ($0.date, $0.id.hex) > ($1.date, $1.id.hex) }
    }

    public func article(_ id: ArticleID) -> StoredArticle? {
        articles[id]
    }

    /// True for live articles and for tombstones: either way it should not be fetched again.
    public func isKnown(_ id: ArticleID) -> Bool {
        articles[id] != nil
    }

    public func epub(for id: ArticleID) throws -> Data {
        guard let article = articles[id], !article.isRetired else { throw ArticleStoreError.unknownArticle(id) }
        guard let data = try? Data(contentsOf: fileURL(for: id)) else { throw ArticleStoreError.missingFile(id) }
        return data
    }

    // MARK: Writing

    /// Package an article and add it. An article that is already known is left untouched.
    @discardableResult
    public func add(_ article: Article, fetchedAt: Date = Date(), load: LoadState = .off) throws -> StoredArticle {
        if let existing = articles[article.id] { return existing }
        var article = article
        if article.source != "PDF" { article.bodyXHTML = ArticleAdControls.clean(article.bodyXHTML) }
        let epub = try EpubBuilder.build(article)
        return try add(
            id: article.id, url: article.url, source: article.source, title: article.title, author: article.author,
            date: article.date, epub: epub, fetchedAt: fetchedAt, load: load,
            preview: Self.preview(ofXHTML: article.bodyXHTML))
    }

    @discardableResult
    public func add(
        id: ArticleID, url: String, source: String, title: String, author: String, date: Date, epub: Data,
        fetchedAt: Date = Date(), load: LoadState = .off, preview: String = ""
    ) throws -> StoredArticle {
        if let existing = articles[id] { return existing }
        try epub.write(to: fileURL(for: id), options: .atomic)
        let stored = StoredArticle(
            id: id, url: url, source: source, title: title, author: author, date: date, fetchedAt: fetchedAt, read: false,
            readAt: nil, onDevice: false, retiredAt: nil, size: epub.count, crc32: CRC32.checksum(epub),
            load: load, preview: preview)
        articles[id] = stored
        try save()
        return stored
    }

    /// A feed fetch may have added the publisher URL while a shared story was being extracted.
    public func addShared(_ article: Article) throws -> StoredArticle {
        if let existing = articles[article.id] {
            if !existing.isRetired {
                try setLoad(article.id, existing.read || existing.load == .lock ? .lock : .load)
                return articles[article.id] ?? existing
            }
            articles[article.id] = nil
            do { return try add(article, load: .load) }
            catch { articles[article.id] = existing; throw error }
        }
        return try add(article, load: .load)
    }

    /// Queue a metadata-only promotion; leave the EPUB, load state and progress untouched.
    public func bump(_ id: ArticleID, at now: Date = Date()) throws {
        guard var article = articles[id], !article.isRetired else { throw ArticleStoreError.unknownArticle(id) }
        let prior = articles.values.reduce(UInt32(0)) { max($0, UInt32(clamping: Int64($1.bumpedAt?.timeIntervalSince1970 ?? 0))) }
        let nonce = max(UInt32(clamping: Int64(now.timeIntervalSince1970)), prior == .max ? prior : prior + 1)
        article.bumpedAt = Date(timeIntervalSince1970: Double(nonce))
        article.pendingBump = nonce
        articles[id] = article
        try save()
    }

    public func pendingBumps() -> [SyncTouch] {
        all().filter(\.wantedOnDevice).compactMap { article in
            article.pendingBump.map { SyncTouch(id: article.id, nonce: $0) }
        }.sorted { $0.nonce < $1.nonce }
    }

    public func didBump(_ touch: SyncTouch) throws {
        guard var article = articles[touch.id], article.pendingBump == touch.nonce else { return }
        article.pendingBump = nil
        articles[touch.id] = article
        try save()
    }

    public func markRead(_ id: ArticleID, at now: Date = Date()) throws {
        guard var article = articles[id] else { throw ArticleStoreError.unknownArticle(id) }
        guard !article.read else { return }
        article.read = true
        article.readAt = now
        articles[id] = article
        try save()
    }

    public func setLoad(_ id: ArticleID, _ load: LoadState) throws {
        guard var article = articles[id], article.load != load else { return }
        // Loading an article that was read asks to read it again: it goes back as unread, or it
        // would be taken straight off.
        if load == .load, article.read {
            article.read = false
            article.readAt = nil
        }
        article.load = load
        articles[id] = article
        try save()
    }

    /// The first `limit` characters of the text of a cleaned XHTML body, tags and entities removed.
    public static func preview(ofXHTML xhtml: String, limit: Int = 280) -> String {
        var text = ""
        var inTag = false
        var lastWasSpace = true
        for character in xhtml {
            if character == "<" {
                inTag = true
                if !lastWasSpace { text.append(" "); lastWasSpace = true }
                continue
            }
            if character == ">" { inTag = false; continue }
            if inTag { continue }
            if character.isWhitespace {
                if !lastWasSpace { text.append(" "); lastWasSpace = true }
            } else {
                text.append(character)
                lastWasSpace = false
            }
            if text.count > limit + 40 { break }
        }
        for (entity, plain) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&#160;", " ")] {
            text = text.replacingOccurrences(of: entity, with: plain)
        }
        text = text.trimmingCharacters(in: .whitespaces)
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        let end = cut.lastIndex(of: " ") ?? cut.endIndex
        return String(cut[..<end]) + "…"
    }

    /// Repair old previews and the phone's EPUB together using the already cached chapter.
    public func backfillPreviews() throws {
        var changed = false
        for (id, var article) in articles where !article.isRetired &&
            (article.preview.isEmpty || (article.source != "PDF" && ArticleAdControls.mayStartWithControl(article.preview))) {
            let url = fileURL(for: id)
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let reader = try? ZipReader(data),
                  let chapter = try? reader.contents(named: "OEBPS/article.xhtml") else { continue }
            let page = String(decoding: chapter, as: UTF8.self)
            guard let start = page.range(of: "<hr/>")?.upperBound,
                  let end = page.range(of: "</body>", options: .backwards)?.lowerBound, start <= end else {
                if article.preview.isEmpty {
                    article.preview = Self.preview(ofXHTML: page)
                    if !article.preview.isEmpty { articles[id] = article; changed = true }
                }
                continue
            }
            let body = String(page[start..<end])
            let cleaned = article.source == "PDF" ? body : ArticleAdControls.clean(body)
            var payload = data
            if cleaned != body {
                let replacement = page.replacingCharacters(in: start..<end, with: cleaned)
                // Paperboy creates stored ZIP entries. Keep their order and every other resource.
                guard reader.entries.allSatisfy({ $0.method == 0 }) else { continue }
                do {
                    var writer = ZipWriter(modified: article.date)
                    for entry in reader.entries {
                        let contents = entry.name == "OEBPS/article.xhtml" ? Data(replacement.utf8) : try reader.contents(of: entry)
                        try writer.add(name: entry.name, contents: contents)
                    }
                    payload = try writer.finish()
                    try payload.write(to: url, options: .atomic)
                } catch { continue }
            }
            let preview = Self.preview(ofXHTML: cleaned)
            // If interrupted after the EPUB replacement, the old preview selects it again on launch.
            guard cleaned != body || preview != article.preview || article.size != payload.count else { continue }
            article.preview = preview
            article.size = payload.count
            article.crc32 = CRC32.checksum(payload)
            articles[id] = article
            changed = true
        }
        if changed { try save() }
    }

    public func setOnDevice(_ id: ArticleID, _ onDevice: Bool) throws {
        guard var article = articles[id], article.onDevice != onDevice else { return }
        article.onDevice = onDevice
        articles[id] = article
        try save()
    }

    /// Bring the flags in line with what the device just listed: which articles it has and
    /// which of them have been opened.
    public func reconcile(deviceListing: [ListItem], now: Date = Date()) throws {
        var listed: [ArticleID: ListItem] = [:]
        for item in deviceListing { listed[item.id] = item }
        var changed = false
        for (id, var article) in articles {
            let item = listed[id]
            let present = item != nil
            if article.onDevice != present {
                article.onDevice = present
                changed = true
            }
            if let item, item.isRead, !article.read {
                article.read = true
                article.readAt = now
                changed = true
            }
            // Read and not locked: it comes off the reader in this sync, and shows as off in the app.
            if article.read, article.load == .load {
                article.load = .off
                changed = true
            }
            articles[id] = article
        }
        if changed { try save() }
    }

    /// Apply the retention rule. Returns the ids retired by this call.
    @discardableResult
    public func applyRetention(_ policy: RetentionPolicy = RetentionPolicy(), now: Date = Date()) throws -> [ArticleID] {
        var retired: [ArticleID] = []
        var changed = false
        for (id, var article) in articles {
            if !article.isRetired, policy.shouldRetire(article, now: now) {
                article.retiredAt = now
                articles[id] = article
                try? FileManager.default.removeItem(at: fileURL(for: id))
                retired.append(id)
                changed = true
            } else if let retiredAt = article.retiredAt, !article.onDevice,
                      now.timeIntervalSince(retiredAt) > policy.tombstoneDays * 86_400
            {
                articles[id] = nil
                changed = true
            }
        }
        if changed { try save() }
        return retired
    }

    /// Articles the reader should hold and does not, newest first.
    public func pendingUploads() -> [StoredArticle] {
        all().filter { $0.wantedOnDevice && !$0.onDevice }
    }

    /// Articles the reader holds and should not: unloaded, read and not locked, or retired.
    public func pendingDeletes() -> [ArticleID] {
        articles.values.filter { $0.onDevice && !$0.wantedOnDevice }.map(\.id).sorted { $0.hex < $1.hex }
    }

    /// Forget an article entirely (file and index entry).
    public func remove(_ id: ArticleID) throws {
        guard articles[id] != nil else { return }
        articles[id] = nil
        try? FileManager.default.removeItem(at: fileURL(for: id))
        try save()
    }
}

/// Feeds a `SyncSession` from an `ArticleStore`.
public struct ArticleStoreSyncSource: SyncDataSource {
    public let store: ArticleStore
    public var policy: RetentionPolicy
    public var now: @Sendable () -> Date

    public init(store: ArticleStore, policy: RetentionPolicy = RetentionPolicy(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.policy = policy
        self.now = now
    }

    public func plan(device: HelloAck, listing: [ListItem]) async throws -> SyncPlan {
        let moment = now()
        try await store.reconcile(deviceListing: listing, now: moment)
        try await store.applyRetention(policy, now: moment)
        let puts = await store.pendingUploads().map {
            SyncItem(id: $0.id, time: $0.date, source: $0.source, title: $0.title, author: $0.author)
        }
        // The phone decides what the reader holds: an article it has never heard of goes too.
        var deletes = await store.pendingDeletes()
        for item in listing where !deletes.contains(item.id) {
            if await !store.isKnown(item.id) { deletes.append(item.id) }
        }
        return SyncPlan(puts: puts, deletes: deletes, touches: await store.pendingBumps())
    }

    public func payload(for id: ArticleID) async throws -> Data {
        try await store.epub(for: id)
    }

    public func didUpload(_ id: ArticleID) async {
        try? await store.setOnDevice(id, true)
    }

    public func didTouch(_ touch: SyncTouch) async { try? await store.didBump(touch) }

    public func didDelete(_ id: ArticleID) async {
        try? await store.setOnDevice(id, false)
    }
}
