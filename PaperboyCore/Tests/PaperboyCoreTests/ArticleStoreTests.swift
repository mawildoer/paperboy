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

    @Test func repairsAdControlsInExistingChapterAndPreviewWithoutLosingReadingStateOrImages() async throws {
        let directory = try makeTempDirectory("paperboy-store")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ArticleStore(directory: directory)
        var old = sample(1)
        let lede = "As November comes to a close, friends ask about leftovers."
        old.bodyXHTML = "<p><em>Advertisement</em><br/><strong>SKIP ADVERTISEMENT</strong></p><p>\(lede)</p><p><img src=\"images/figure.png\" alt=\"Plot\"/></p>"
        let chart = try MonochromeImage.encode(ImagePipelineTests.chart(), path: "images/figure.png", preferChart: true)
        old.images = [chart]
        let data = try EpubBuilder.build(old)
        try await store.add(id: old.id, url: old.url, source: old.source, title: old.title, author: old.author,
                            date: old.date, epub: data, load: .lock, preview: "Advertisement SKIP ADVERTISEMENT " + lede)
        try await store.setOnDevice(old.id, true)
        try await store.bump(old.id, at: t0)
        try await store.backfillPreviews()
        let reopened = try ArticleStore(directory: directory)
        let record = try #require(await reopened.article(old.id))
        #expect(record.preview == lede)
        #expect(record.onDevice && record.load == .lock && record.pendingBump != nil)
        let repaired = try await reopened.epub(for: old.id)
        let zip = try ZipReader(repaired)
        #expect(try zip.contents(named: "OEBPS/images/figure.png") == chart.data)
        #expect(try !String(decoding: zip.contents(named: "OEBPS/article.xhtml"), as: UTF8.self).contains("ADVERTISEMENT"))
        #expect(record.size == repaired.count && record.crc32 == CRC32.checksum(repaired))
        try await reopened.backfillPreviews()
        #expect(try await reopened.epub(for: old.id) == repaired)
    }

    @Test func joinedAdLabelsAreRemovedBeforeStoringNewShares() async throws {
        let directory = try makeTempDirectory("paperboy-store")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ArticleStore(directory: directory)
        var article = sample(1)
        article.bodyXHTML = "<p>Advertisement SKIP ADVERTISEMENT The actual story.</p><blockquote><p>Advertisement</p></blockquote><p>Advertisement revenue rose.</p>"
        let saved = try await store.addShared(article)
        #expect(saved.preview == "The actual story. Advertisement Advertisement revenue rose.")
        try await store.setLoad(saved.id, .lock)
        #expect(try await store.addShared(article).load == .lock)
        #expect(await store.all().count == 1)
    }

    @Test func refreshReplacesPhoneContentAndPreservesReadingState() async throws {
        let directory = try makeTempDirectory("paperboy-store")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ArticleStore(directory: directory)
        let original = sample(1)
        let stored = try await store.add(original, fetchedAt: t0)
        try await store.markRead(stored.id, at: t0.addingTimeInterval(day))
        try await store.setOnDevice(stored.id, true)
        try await store.bump(stored.id, at: t0)
        let before = try #require(await store.article(stored.id))
        let oldEPUB = try await store.epub(for: stored.id)

        var article = original
        article.title = "Revised headline"
        article.author = "New byline"
        article.source = "Publisher"
        article.date = t0.addingTimeInterval(2 * day)
        article.bodyXHTML = "<p>Advertisement SKIP ADVERTISEMENT The complete story.</p>"
        let refreshed = try await store.addShared(article, refreshExisting: true, publisher: .substack)
        var cleaned = article
        cleaned.bodyXHTML = ArticleAdControls.clean(article.bodyXHTML)
        let newEPUB = try EpubBuilder.build(cleaned)
        #expect(newEPUB != oldEPUB)
        var expected = before
        expected.title = article.title
        expected.author = article.author
        expected.source = article.source
        expected.date = article.date
        expected.preview = "The complete story."
        expected.size = newEPUB.count
        expected.crc32 = CRC32.checksum(newEPUB)
        expected.load = .lock
        expected.sharedPublisher = .substack
        #expect(refreshed == expected)
        let reopened = try ArticleStore(directory: directory)
        #expect(await reopened.all() == [expected])
        #expect(try await reopened.epub(for: stored.id) == newEPUB)

        let source = ArticleStoreSyncSource(store: reopened)
        let existingReader = FakeDevice()
        existingReader.seed(id: stored.id, data: oldEPUB, read: true)
        let present = await SyncSession(transport: FakeDeviceTransport(device: existingReader), source: source).run()
        #expect(present.completed && present.uploaded.isEmpty && present.deleted.isEmpty)
        #expect(!existingReader.receivedTypes.contains(.putBegin))
        #expect(existingReader.article(stored.id)?.data == oldEPUB)
        let emptyReader = FakeDevice()
        let absent = await SyncSession(transport: FakeDeviceTransport(device: emptyReader), source: source).run()
        #expect(absent.completed && absent.uploaded == [stored.id])
        #expect(emptyReader.article(stored.id)?.data == newEPUB)
    }

    @Test func defaultShareQueuesCachedContentAndIdenticalRefreshAvoidsRewrites() async throws {
        let directory = try makeTempDirectory("paperboy-store")
        let files = FileManager.default
        defer { try? files.removeItem(at: directory) }
        let store = try ArticleStore(directory: directory)
        let article = sample(1)
        let stored = try await store.add(article, publisher: .medium)
        let file = await store.fileURL(for: stored.id)
        let index = directory.appendingPathComponent("index.json")
        try files.setAttributes([.modificationDate: t0], ofItemAtPath: file.path)
        var other = article
        other.bodyXHTML = "<p>Another version.</p>"
        let queued = try await store.addShared(other)
        #expect(queued.load == .load && queued.preview == stored.preview)
        #expect(queued.sharedPublisher == .medium && !queued.onDevice)
        #expect(try await store.epub(for: stored.id) == EpubBuilder.build(article))
        try await store.setLoad(stored.id, .lock)
        try files.setAttributes([.modificationDate: t0], ofItemAtPath: index.path)
        let refreshed = try await store.addShared(article, refreshExisting: true)
        #expect(refreshed.load == .lock && !refreshed.read && refreshed.sharedPublisher == .medium)
        #expect(try files.attributesOfItem(atPath: file.path)[.modificationDate] as? Date == t0)
        #expect(try files.attributesOfItem(atPath: index.path)[.modificationDate] as? Date == t0)
        #expect(await store.pendingUploads().map(\.id) == [stored.id])
    }

    @Test func publisherCanBeLearnedForAnOlderIndexWithoutChangingTheEpub() async throws {
        let directory = try makeTempDirectory("paperboy-store")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ArticleStore(directory: directory)
        let first = try await store.addShared(sample(1))
        let index = directory.appendingPathComponent("index.json")
        #expect(try !String(contentsOf: index, encoding: .utf8).contains("sharedPublisher"))
        let reopened = try ArticleStore(directory: directory)
        #expect(await reopened.article(first.id) == first)
        let url = await reopened.fileURL(for: first.id)
        try FileManager.default.setAttributes([.modificationDate: t0], ofItemAtPath: url.path)
        let identified = try await reopened.addShared(sample(1), refreshExisting: true, publisher: .medium)
        #expect(identified.sharedPublisher == .medium)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == t0)
        let second = try await reopened.addShared(sample(2), publisher: .substack)
        let again = try ArticleStore(directory: directory)
        #expect(await again.article(first.id)?.sharedPublisher == .medium)
        #expect(await again.article(second.id)?.sharedPublisher == .substack)
    }

    @Test func failedRefreshKeepsGoodContentAndCanBeRetried() async throws {
        let directory = try makeTempDirectory("paperboy-store")
        let files = FileManager.default
        defer { try? files.removeItem(at: directory) }
        let store = try ArticleStore(directory: directory)
        let first = try await store.add(sample(1), fetchedAt: t0, publisher: .medium)
        let oldEPUB = try await store.epub(for: first.id)
        var revised = sample(1)
        revised.bodyXHTML = "<p>The full story.</p>"
        var invalid = revised
        invalid.images = [ArticleImage(path: "invalid", data: Data(), width: 1, height: 1)]
        await #expect(throws: EpubBuilder.Failure.invalidImage) {
            try await store.addShared(invalid, refreshExisting: true, publisher: .substack)
        }
        #expect(await store.article(first.id) == first)
        #expect(try await store.epub(for: first.id) == oldEPUB)

        // Fail the final rename after writing the replacement EPUB.
        let index = directory.appendingPathComponent("index.json")
        let savedIndex = directory.appendingPathComponent("saved-index")
        try files.moveItem(at: index, to: savedIndex)
        try files.createDirectory(at: index, withIntermediateDirectories: false)
        await #expect(throws: POSIXError.self) {
            try await store.addShared(revised, refreshExisting: true, publisher: .substack)
        }
        #expect(await store.article(first.id) == first)
        #expect(try await store.epub(for: first.id) == oldEPUB)
        try files.removeItem(at: index)
        try files.moveItem(at: savedIndex, to: index)
        let reopened = try ArticleStore(directory: directory)
        #expect(await reopened.article(first.id) == first)
        #expect(try await reopened.epub(for: first.id) == oldEPUB)
        let refreshed = try await store.addShared(revised, refreshExisting: true, publisher: .substack)
        #expect(refreshed.load == .load && refreshed.preview == "The full story.")
        #expect(refreshed.sharedPublisher == .substack && refreshed.fetchedAt == first.fetchedAt)
        let afterRetry = try ArticleStore(directory: directory)
        #expect(await afterRetry.article(first.id) == refreshed)
        #expect(try await afterRetry.epub(for: first.id) == EpubBuilder.build(revised))
    }

    @Test func refreshCanRestoreMissingBytesAndReviveARetiredShare() async throws {
        let directory = try makeTempDirectory("paperboy-store")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ArticleStore(directory: directory)
        let article = sample(1)
        let first = try await store.addShared(article, publisher: .medium)
        let url = await store.fileURL(for: first.id)
        try FileManager.default.removeItem(at: url)
        #expect(try await store.addShared(article, refreshExisting: true) == first)
        #expect(try await store.epub(for: first.id) == EpubBuilder.build(article))

        try await store.markRead(first.id, at: t0)
        try await store.setOnDevice(first.id, true)
        try await store.applyRetention(now: t0.addingTimeInterval(3 * day))
        let retired = try #require(await store.article(first.id))
        #expect(retired.isRetired)
        var expected = retired
        expected.retiredAt = nil
        expected.load = .lock
        #expect(try await store.addShared(article, refreshExisting: true) == expected)
        #expect(try await store.epub(for: first.id) == EpubBuilder.build(article))
    }

    @Test(arguments: [false, true])
    func reopeningResolvesInterruptedRefresh(indexCommitted: Bool) async throws {
        let directory = try makeTempDirectory("paperboy-store")
        let files = FileManager.default
        defer { try? files.removeItem(at: directory) }
        let store = try ArticleStore(directory: directory)
        let original = sample(1)
        let first = try await store.add(original, fetchedAt: t0)
        let epub = await store.fileURL(for: first.id)
        var revised = original
        revised.title = "Latest title"
        let oldEPUB = try EpubBuilder.build(original)
        let newEPUB = try EpubBuilder.build(revised)
        let index = directory.appendingPathComponent("index.json")
        let oldIndex = try Data(contentsOf: index)
        let refreshed = try await store.addShared(revised, refreshExisting: true)
        let journal = directory.appendingPathComponent(".refresh")
        try files.createDirectory(at: journal, withIntermediateDirectories: false)
        try oldEPUB.write(to: journal.appendingPathComponent(epub.lastPathComponent))
        if !indexCommitted {
            try files.moveItem(at: index, to: journal.appendingPathComponent("index.json"))
            try oldIndex.write(to: index, options: .atomic)
        }
        let reopened = try ArticleStore(directory: directory)
        #expect(await reopened.article(first.id) == (indexCommitted ? refreshed : first))
        #expect(try await reopened.epub(for: first.id) == (indexCommitted ? newEPUB : oldEPUB))
        #expect(!files.fileExists(atPath: journal.path))
    }

    @Test func previewIsPlainText() {
        let text = ArticleStore.preview(ofXHTML: "<p>Tom &amp; Jerry <em>ran</em>.</p>\n<p>Then   stopped.</p>")
        #expect(text == "Tom & Jerry ran . Then stopped." || text == "Tom & Jerry ran. Then stopped.")
        let long = ArticleStore.preview(ofXHTML: "<p>" + String(repeating: "word ", count: 200) + "</p>", limit: 50)
        #expect(long.count <= 51 && long.hasSuffix("…"))
    }
}

@Suite struct BumpTests {
    @Test func bumpPersistsAndOnlyAcknowledgesTheMatchingRequest() async throws {
        let directory = try makeTempDirectory("paperboy-bump")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ArticleStore(directory: directory)
        let article = try await store.add(sample(1), fetchedAt: t0, load: .lock)
        try await store.markRead(article.id, at: t0)
        let original = try await store.epub(for: article.id)
        try await store.bump(article.id, at: t0.addingTimeInterval(10))
        let request = try #require(await store.pendingBumps().first)
        try await store.bump(article.id, at: t0.addingTimeInterval(10))
        try await store.didBump(request)
        let current = try #require(await store.article(article.id))
        #expect(current.pendingBump == request.nonce + 1)
        #expect(current.read && current.load == .lock)
        #expect(current.date == article.date && current.fetchedAt == article.fetchedAt)
        #expect(try await store.epub(for: article.id) == original)
        let reopened = try ArticleStore(directory: directory)
        #expect(await reopened.pendingBumps().first?.nonce == request.nonce + 1)
    }
    @Test func syncPromotesAnExistingArticleWithoutUploadingItsEpub() async throws {
        let directory = try makeTempDirectory("paperboy-bump-sync")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ArticleStore(directory: directory)
        let article = try await store.add(sample(2), load: .load)
        let device = FakeDevice()
        device.seed(id: article.id, data: Data("existing EPUB and saved position".utf8))
        try await store.bump(article.id)
        let report = await SyncSession(transport: FakeDeviceTransport(device: device), source: ArticleStoreSyncSource(store: store)).run()
        #expect(report.completed)
        #expect(report.bumped == [article.id])
        #expect(report.uploaded.isEmpty)
        #expect(!device.receivedTypes.contains(.putBegin))
        #expect(await store.pendingBumps().isEmpty)
        #expect(device.article(article.id)?.data == Data("existing EPUB and saved position".utf8))
    }
    @Test func oldFirmwareKeepsBumpsQueuedWhileBasicSyncStillCompletes() async throws {
        let directory = try makeTempDirectory("paperboy-bump-old")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ArticleStore(directory: directory)
        let article = try await store.add(sample(2), load: .load)
        let device = FakeDevice(); device.setProtocolVersion(1); device.seed(id: article.id)
        try await store.bump(article.id)
        let report = await SyncSession(transport: FakeDeviceTransport(device: device), source: ArticleStoreSyncSource(store: store)).run()
        #expect(report.completed && report.bumped.isEmpty)
        #expect(await store.pendingBumps().count == 1)
        #expect(!device.receivedTypes.contains(.touch))
    }
    @Test func uploadThenBumpQueuesInTheRightOrder() async throws {
        let directory = try makeTempDirectory("paperboy-bump-upload")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ArticleStore(directory: directory)
        let article = try await store.add(sample(3), load: .load)
        try await store.bump(article.id)
        let device = FakeDevice()
        let report = await SyncSession(transport: FakeDeviceTransport(device: device), source: ArticleStoreSyncSource(store: store)).run()
        #expect(report.completed && report.uploaded == [article.id] && report.bumped == [article.id])
        #expect(device.receivedTypes.firstIndex(of: .putEnd)! < device.receivedTypes.firstIndex(of: .touch)!)
    }
}

@Suite struct BumpOrderingTests {
    @Test func tapsInTheSameSecondHaveAnUnambiguousOrderAcrossArticles() async throws {
        let directory = try makeTempDirectory("paperboy-bump-order")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ArticleStore(directory: directory)
        let a = try await store.add(sample(1), load: .load)
        let b = try await store.add(sample(2), load: .load)
        try await store.bump(a.id, at: t0)
        try await store.bump(b.id, at: t0)
        let pending = await store.pendingBumps()
        #expect(pending.map(\.id) == [a.id, b.id])
        #expect(pending[0].nonce < pending[1].nonce)
    }
}
