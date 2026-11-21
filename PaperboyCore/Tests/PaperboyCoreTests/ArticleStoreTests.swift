import Foundation
import Testing

@testable import PaperboyCore

private let day: TimeInterval = 86_400
private let t0 = Date(timeIntervalSince1970: 1_794_744_000)

private func sample(_ n: Int, date: Date = t0) -> Article {
    Article(
        url: "https://example.com/p/article-\(n)", source: "Example", title: "Article \(n)", author: "Author \(n)",
        date: date.addingTimeInterval(Double(n)), bodyXHTML: "<p>Body \(n)</p>\n")
}

@Suite struct ArticleStoreTests {
    @Test func addsReadsAndPersists() async throws {
        let directory = try makeTempDirectory("paperboy-store")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ArticleStore(directory: directory)
        let stored = try await store.add(sample(1), fetchedAt: t0)
        try await store.add(sample(2), fetchedAt: t0)

        #expect(stored.id == sample(1).id)
        #expect(stored.read == false)
        #expect(stored.onDevice == false)
        #expect(stored.fetchedAt == t0)
        let epub = try await store.epub(for: stored.id)
        #expect(epub == (try EpubBuilder.build(sample(1))))
        #expect(stored.size == epub.count)
        #expect(stored.crc32 == CRC32.checksum(epub))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(stored.id.hex).epub").path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.json").path))

        // Newest first.
        #expect(await store.all().map(\.title) == ["Article 2", "Article 1"])

        // Adding again changes nothing.
        let again = try await store.add(sample(1), fetchedAt: t0.addingTimeInterval(999))
        #expect(again.fetchedAt == t0)
        #expect(await store.all().count == 2)

        try await store.markRead(stored.id, at: t0.addingTimeInterval(60))
        try await store.setOnDevice(stored.id, true)

        // A second store on the same directory sees everything.
        let reopened = try ArticleStore(directory: directory)
        let loaded = try #require(await reopened.article(stored.id))
        #expect(loaded.read)
        #expect(loaded.readAt == t0.addingTimeInterval(60))
        #expect(loaded.onDevice)
        #expect(loaded.title == "Article 1")
        #expect(await reopened.all().count == 2)
        #expect(try await reopened.epub(for: stored.id) == epub)
    }

    @Test func survivesACorruptIndex() async throws {
        let directory = try makeTempDirectory("paperboy-store")
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{ not json".utf8).write(to: directory.appendingPathComponent("index.json"))
        let store = try ArticleStore(directory: directory)
        #expect(await store.all().isEmpty)
        try await store.add(sample(1))
        #expect(await store.all().count == 1)
    }

    @Test func retentionRule() {
        let policy = RetentionPolicy()
        var article = StoredArticle(
            id: sample(1).id, url: "u", source: "s", title: "t", author: "a", date: t0, fetchedAt: t0, read: false, readAt: nil,
            onDevice: true, retiredAt: nil, size: 1, crc32: 1)
        // Unread: 14 days from fetch.
        #expect(!policy.shouldRetire(article, now: t0.addingTimeInterval(13.9 * day)))
        #expect(policy.shouldRetire(article, now: t0.addingTimeInterval(14.1 * day)))
        // Read: 2 days from when it was read, however old it is.
        article.read = true
        article.readAt = t0.addingTimeInterval(13 * day)
        #expect(!policy.shouldRetire(article, now: t0.addingTimeInterval(14.9 * day)))
        #expect(policy.shouldRetire(article, now: t0.addingTimeInterval(15.1 * day)))
        // Read early: gone after 2 days, long before the 14.
        article.readAt = t0.addingTimeInterval(1 * day)
        #expect(policy.shouldRetire(article, now: t0.addingTimeInterval(3.1 * day)))
    }

    @Test func retirementKeepsATombstoneUntilTheDeviceIsClean() async throws {
        let directory = try makeTempDirectory("paperboy-store")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ArticleStore(directory: directory)
        let old = try await store.add(sample(1), fetchedAt: t0)
        let fresh = try await store.add(sample(2), fetchedAt: t0.addingTimeInterval(10 * day), load: .load)
        try await store.setOnDevice(old.id, true)

        let now = t0.addingTimeInterval(15 * day)
        #expect(try await store.applyRetention(now: now) == [old.id])
        #expect(await store.all().map(\.id) == [fresh.id])
        #expect(await store.isKnown(old.id))  // not fetched again
        #expect(await store.pendingDeletes() == [old.id])
        #expect(await store.pendingUploads().map(\.id) == [fresh.id])
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(old.id.hex).epub").path))
        await #expect(throws: ArticleStoreError.unknownArticle(old.id)) { try await store.epub(for: old.id) }

        // Applying again retires nothing new.
        #expect(try await store.applyRetention(now: now).isEmpty)

        // Once the device has deleted it, the tombstone stays for a while, then goes.
        try await store.setOnDevice(old.id, false)
        #expect(await store.pendingDeletes().isEmpty)
        try await store.applyRetention(RetentionPolicy(unreadDays: 1000), now: now.addingTimeInterval(59 * day))
        #expect(await store.isKnown(old.id))
        try await store.applyRetention(RetentionPolicy(unreadDays: 1000), now: now.addingTimeInterval(61 * day))
        #expect(!(await store.isKnown(old.id)))
    }

    @Test func reconcileTakesReadAndPresenceFromTheDevice() async throws {
        let directory = try makeTempDirectory("paperboy-store")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ArticleStore(directory: directory)
        let a = try await store.add(sample(1), fetchedAt: t0)
        let b = try await store.add(sample(2), fetchedAt: t0)
        let c = try await store.add(sample(3), fetchedAt: t0, load: .load)
        try await store.setOnDevice(c.id, true)
        let stranger = ArticleID(canonicalURL: "https://elsewhere.example/x")

        let now = t0.addingTimeInterval(day)
        try await store.reconcile(
            deviceListing: [ListItem(id: a.id, read: true), ListItem(id: b.id, read: false), ListItem(id: stranger, read: true)], now: now)
        let a2 = try #require(await store.article(a.id))
        #expect(a2.onDevice && a2.read && a2.readAt == now)
        let b2 = try #require(await store.article(b.id))
        #expect(b2.onDevice && !b2.read)
        // The device no longer lists c (card wiped?): it is offered again.
        let c2 = try #require(await store.article(c.id))
        #expect(!c2.onDevice)
        #expect(!(await store.isKnown(stranger)))
        #expect(await store.pendingUploads().map(\.id) == [c.id])
    }

    @Test func loadStatesDecideWhatTheReaderHolds() async throws {
        let directory = try makeTempDirectory("paperboy-store")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ArticleStore(directory: directory)
        let off = try await store.add(sample(1), fetchedAt: t0)
        let loaded = try await store.add(sample(2), fetchedAt: t0)
        let locked = try await store.add(sample(3), fetchedAt: t0)
        #expect(off.load == .off && !off.preview.isEmpty)
        // Nothing goes to the reader until it is asked for.
        #expect(await store.pendingUploads().isEmpty)

        try await store.setLoad(loaded.id, .load)
        try await store.setLoad(locked.id, .lock)
        #expect(Set(await store.pendingUploads().map(\.id)) == [loaded.id, locked.id])
        try await store.setOnDevice(loaded.id, true)
        try await store.setOnDevice(locked.id, true)

        // Both are read on the reader: the loaded one comes off, the locked one stays.
        let now = t0.addingTimeInterval(day)
        try await store.reconcile(deviceListing: [ListItem(id: loaded.id, read: true), ListItem(id: locked.id, read: true)], now: now)
        #expect(await store.pendingDeletes() == [loaded.id])
        #expect(await store.article(loaded.id)?.load == .off)
        #expect(await store.article(locked.id)?.load == .lock)
        // Loading the read one again makes it unread, so it is sent and stays until read again.
        try await store.setOnDevice(loaded.id, false)
        try await store.setLoad(loaded.id, .load)
        #expect(await store.article(loaded.id)?.read == false)
        #expect(await store.pendingUploads().map(\.id) == [loaded.id])
        try await store.setLoad(loaded.id, .off)
        try await store.setOnDevice(loaded.id, true)
        try await store.markRead(loaded.id, at: now)
        // A locked article is never retired, however old.
        try await store.applyRetention(now: t0.addingTimeInterval(400 * day))
        #expect(await store.article(locked.id)?.isRetired == false)

        // Unlocking takes it off at the next sync; switching off an unread one does too.
        try await store.setLoad(locked.id, .off)
        #expect(Set(await store.pendingDeletes()) == [loaded.id, locked.id])
        #expect(LoadState.off.next == .load && LoadState.load.next == .lock && LoadState.lock.next == .off)
    }

    @Test func previewIsPlainText() {
        let text = ArticleStore.preview(ofXHTML: "<p>Tom &amp; Jerry <em>ran</em>.</p>\n<p>Then   stopped.</p>")
        #expect(text == "Tom & Jerry ran . Then stopped." || text == "Tom & Jerry ran. Then stopped.")
        let long = ArticleStore.preview(ofXHTML: "<p>" + String(repeating: "word ", count: 200) + "</p>", limit: 50)
        #expect(long.count <= 51 && long.hasSuffix("…"))
    }
}
