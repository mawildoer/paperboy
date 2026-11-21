import Foundation
import Testing

@testable import PaperboyCore

private let fixedNow = Date(timeIntervalSince1970: 1_794_744_000)

private func fastConfig() -> SyncConfig {
    var config = SyncConfig()
    // Generous where nothing should ever time out (so a busy machine cannot fail a test),
    // short only for the one wait that the stall tests sit through.
    config.helloTimeout = .seconds(5)
    config.listTimeout = .seconds(5)
    config.putReadyTimeout = .seconds(5)
    config.progressTimeout = .milliseconds(300)
    config.putResultTimeout = .seconds(5)
    config.deleteTimeout = .seconds(5)
    config.now = { fixedNow }
    return config
}

/// Pseudo-random but reproducible payload of a given size.
private func payload(_ size: Int, seed: UInt64) -> Data {
    var generator = SplitMix64(seed: seed)
    var data = Data(capacity: size)
    while data.count < size {
        var word = generator.next()
        for _ in 0..<8 where data.count < size {
            data.append(UInt8(truncatingIfNeeded: word))
            word >>= 8
        }
    }
    return data
}

private func item(_ n: Int, size: Int) -> (item: SyncItem, data: Data) {
    let id = ArticleID(canonicalURL: "https://example.com/p/sync-\(n)")
    return (
        SyncItem(id: id, time: fixedNow.addingTimeInterval(Double(n)), source: "Source \(n)", title: "Title \(n)", author: "Author \(n)"),
        payload(size, seed: UInt64(n) + 1)
    )
}

private func demoItems() throws -> [(item: SyncItem, data: Data)] {
    try DemoArticles.articles.map { ($0.syncItem, try EpubBuilder.build($0)) }
}

final class LogCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

/// A device driven by a closure, for misbehaviour the well-behaved FakeDevice cannot produce.
final class ScriptedTransport: SyncTransport, @unchecked Sendable {
    private let inbox = FrameInbox()
    private let respond: @Sendable (Frame) -> [Data]
    private let lock = NSLock()
    private var sentFrames: [Frame] = []

    init(respond: @escaping @Sendable (Frame) -> [Data]) {
        self.respond = respond
    }

    var sent: [Frame] { lock.withLock { sentFrames } }

    func maxWriteLength(withResponse: Bool) async -> Int { withResponse ? 512 : 182 }

    func send(_ frame: Data, withResponse: Bool) async throws {
        let decoded = try Frame.decode(frame)
        lock.withLock { sentFrames.append(decoded) }
        for response in respond(decoded) { inbox.push(response) }
    }

    func receive(timeout: Duration) async throws -> Data {
        try await inbox.next(timeout: timeout)
    }
}

private func enc(_ frame: Frame) -> Data {
    (try? frame.encode()) ?? Data()
}

@Suite struct SyncSessionTests {
    @Test func fullSessionAgainstAnEmptyDevice() async throws {
        let items = try demoItems()
        let device = FakeDevice()
        let transport = FakeDeviceTransport(device: device)
        let source = StaticSyncSource(items: items)
        let log = LogCollector()
        let report = await SyncSession(transport: transport, source: source, config: fastConfig(), log: { log.add($0) }).run()

        #expect(report.completed, "\(String(describing: report.error))")
        #expect(report.device == HelloAck(version: 1, batteryPercent: 87, freeSpaceMB: 512, firmwareVersion: "paperboy-fake-1.0"))
        #expect(report.listing.isEmpty)
        #expect(report.uploaded == items.map(\.item.id))
        #expect(report.alreadyPresent.isEmpty)
        #expect(report.deleted.isEmpty)
        #expect(report.failures.isEmpty)
        #expect(report.bytesSent == items.reduce(0) { $0 + $1.data.count })
        #expect(source.uploaded == items.map(\.item.id))

        // The device has exactly what was sent, byte for byte, with the metadata.
        #expect(device.articles.count == 3)
        for (item, data) in items {
            let stored = try #require(device.article(item.id))
            #expect(stored.data == data)
            #expect(stored.title == item.title)
            #expect(stored.source == item.source)
            #expect(stored.author == item.author)
            #expect(stored.time == UInt32(item.time.timeIntervalSince1970))
            #expect(!stored.read)
            // What arrived is a valid EPUB.
            #expect(try ZipReader(stored.data).entries.map(\.name) == EpubBuilder.entryNames)
        }
        #expect(device.violations.isEmpty, "\(device.violations)")
        #expect(transport.oversizedWrites == 0)
        #expect(device.helloCount == 1)
        #expect(device.lastHelloTime == 1_794_744_000)
        #expect(!device.radioOn)  // BYE was received
        #expect(!device.hasLeftoverTemp)

        // Frame order: HELLO, LIST, then for each article PUT_BEGIN, PUT_DATA…, PUT_END, then BYE.
        var types = device.receivedTypes
        #expect(types.removeFirst() == .hello)
        #expect(types.removeFirst() == .list)
        #expect(types.removeLast() == .bye)
        var collapsed: [FrameType] = []
        for type in types where !(type == .putData && collapsed.last == .putData) { collapsed.append(type) }
        #expect(collapsed == [.putBegin, .putData, .putEnd, .putBegin, .putData, .putEnd, .putBegin, .putData, .putEnd])

        // The log shows the conversation and never the article bytes.
        #expect(log.all.contains { $0.hasPrefix("→ HELLO v1") })
        #expect(log.all.contains { $0.hasPrefix("← HELLO_ACK") })
        #expect(log.all.contains { $0.hasPrefix("← PUT_RESULT ok") })
        #expect(log.all.last == "→ BYE")
    }

    @Test func skipsWhatTheDeviceAlreadyHas() async throws {
        let items = [item(1, size: 5000), item(2, size: 6000), item(3, size: 7000)]
        let device = FakeDevice()
        device.seed(id: items[1].item.id, data: items[1].data, read: true)
        let stranger = ArticleID(canonicalURL: "https://elsewhere.example/pushed-by-the-cli")
        device.seed(id: stranger)
        let transport = FakeDeviceTransport(device: device)
        let report = await SyncSession(transport: transport, source: StaticSyncSource(items: items), config: fastConfig()).run()

        #expect(report.completed)
        #expect(report.listing == [ListItem(id: items[1].item.id, read: true), ListItem(id: stranger, read: false)])
        #expect(report.uploaded == [items[0].item.id, items[2].item.id])
        #expect(device.receivedTypes.filter { $0 == .putBegin }.count == 2)
        #expect(device.articles.count == 4)  // the stranger is left alone
        #expect(device.violations.isEmpty)
    }

    @Test func existsAnswerCountsAsPresent() async throws {
        let items = [item(1, size: 3000), item(2, size: 3000)]
        let device = FakeDevice()
        device.forcePutReady([.exists])
        let transport = FakeDeviceTransport(device: device)
        let source = StaticSyncSource(items: items)
        let report = await SyncSession(transport: transport, source: source, config: fastConfig()).run()
        #expect(report.completed)
        #expect(report.alreadyPresent == [items[0].item.id])
        #expect(report.uploaded == [items[1].item.id])
        #expect(source.uploaded == items.map(\.item.id))
        #expect(device.receivedTypes.filter { $0 == .putData }.count == transport.dataFrames)
    }

    @Test func deletesOnlyRetiredArticlesTheDeviceHas() async throws {
        let kept = item(1, size: 2000)
        let retired = ArticleID(canonicalURL: "https://example.com/p/retired")
        let neverThere = ArticleID(canonicalURL: "https://example.com/p/never-on-device")
        let device = FakeDevice()
        device.seed(id: kept.item.id, data: kept.data)
        device.seed(id: retired)
        let transport = FakeDeviceTransport(device: device)
        let source = StaticSyncSource(items: [kept], deletes: [retired, neverThere])
        let report = await SyncSession(transport: transport, source: source, config: fastConfig()).run()

        #expect(report.completed)
        #expect(report.deleted == [retired])
        #expect(source.deleted == [retired])
        #expect(device.articles.map(\.id) == [kept.item.id])
        #expect(device.receivedTypes == [.hello, .list, .delete, .bye])
    }

    @Test(arguments: [23, 64, 185, 247, 517])
    func flowControlWindowIsRespected(mtu: Int) async throws {
        // Sizes around the interesting edges: tiny, exactly one progress step, one window, large.
        let sizes = [1, 4095, 4096, 4097, 8192, 8193, 20_000, 150_001]
        let items = sizes.enumerated().map { item($0.offset + 10, size: $0.element) }
        let device = FakeDevice()
        let transport = FakeDeviceTransport(device: device, attMTU: mtu)
        let report = await SyncSession(transport: transport, source: StaticSyncSource(items: items), config: fastConfig()).run()

        #expect(report.completed, "\(String(describing: report.error))")
        #expect(report.uploaded.count == sizes.count)
        #expect(report.failures.isEmpty)
        // The device records a violation whenever it holds more than 8192 unreported bytes.
        #expect(device.violations.isEmpty, "\(device.violations)")
        #expect(transport.oversizedWrites == 0)
        for (item, data) in items {
            #expect(device.article(item.id)?.data == data)
        }
        // Chunks are as large as one write allows: MTU − 3 bytes including the type byte.
        let total = sizes.reduce(0, +)
        let chunk = mtu - 3 - 1
        let expectedFrames = sizes.reduce(0) { $0 + ($1 + chunk - 1) / chunk }
        #expect(transport.dataFrames == expectedFrames)
        #expect(transport.dataBytesWritten == total)
    }

    @Test func stopsAtTheWindowWhenProgressStalls() async throws {
        let big = item(1, size: 60_000)
        let small = item(2, size: 500)
        let device = FakeDevice()
        let transport = FakeDeviceTransport(device: device, attMTU: 185)
        transport.dropProgressNotifications(true)
        let log = LogCollector()
        let report = await SyncSession(transport: transport, source: StaticSyncSource(items: [big, small]), config: fastConfig(), log: { log.add($0) }).run()

        // With no PUT_PROGRESS at all the phone may send at most 8192 bytes of an article. It
        // then asks for the verdict with PUT_END (the device says the file is short), tries
        // once more, and moves on to the next article.
        #expect(report.completed, "\(String(describing: report.error))")
        #expect(report.failures == [SyncFailure(id: big.item.id, reason: "checksum mismatch")])
        #expect(report.uploaded == [small.item.id])
        let perAttempt = (transport.dataBytesWritten - 500) / 2
        #expect(perAttempt <= 8192)
        #expect(perAttempt > 8192 - 182)  // as many whole chunks as fit in the window
        #expect(device.violations.isEmpty, "\(device.violations)")
        #expect(device.article(big.item.id) == nil)
        #expect(device.receivedTypes.filter { $0 == .putBegin }.count == 3)
        #expect(log.all.contains { $0.contains("window full") })
    }

    @Test func deadDeviceDuringTransferTimesOut() async throws {
        let big = item(1, size: 60_000)
        let device = FakeDevice()
        let transport = FakeDeviceTransport(device: device, attMTU: 185)
        // After PUT_READY the device says nothing more.
        final class GoQuiet: SyncTransport, @unchecked Sendable {
            let inner: FakeDeviceTransport
            init(_ inner: FakeDeviceTransport) { self.inner = inner }
            func maxWriteLength(withResponse: Bool) async -> Int { await inner.maxWriteLength(withResponse: withResponse) }
            func send(_ frame: Data, withResponse: Bool) async throws {
                try await inner.send(frame, withResponse: withResponse)
                if frame.first == FrameType.putData.rawValue { inner.muteDevice(true) }
            }
            func receive(timeout: Duration) async throws -> Data { try await inner.receive(timeout: timeout) }
        }
        var config = fastConfig()
        config.putResultTimeout = .milliseconds(300)
        let report = await SyncSession(transport: GoQuiet(transport), source: StaticSyncSource(items: [big]), config: config).run()
        #expect(report.error == .timeout("PUT_RESULT"))
        #expect(report.uploaded.isEmpty)
        #expect(transport.dataBytesWritten <= 8192)
        #expect(device.receivedTypes.last == .bye)  // the link is still up, so the session said goodbye
    }

    @Test func emptyArticleIsRefusedByTheDevice() async throws {
        let empty = item(1, size: 0)
        let ok = item(2, size: 10)
        let device = FakeDevice()
        let report = await SyncSession(transport: FakeDeviceTransport(device: device), source: StaticSyncSource(items: [empty, ok]), config: fastConfig()).run()
        #expect(report.completed)
        #expect(report.failures == [SyncFailure(id: empty.item.id, reason: "bad request")])
        #expect(report.uploaded == [ok.item.id])
    }

    @Test func droppedConnectionMidTransferThenResume() async throws {
        let items = [item(1, size: 12_000), item(2, size: 40_000), item(3, size: 9_000)]
        let device = FakeDevice()
        let transport = FakeDeviceTransport(device: device)
        let source = StaticSyncSource(items: items)
        // The link dies 15000 bytes into the second article.
        transport.dropConnection(afterDataBytes: 12_000 + 15_000)

        let first = await SyncSession(transport: transport, source: source, config: fastConfig()).run()
        #expect(first.error == .disconnected)
        #expect(first.uploaded == [items[0].item.id])
        #expect(source.uploaded == [items[0].item.id])  // progress was recorded before the drop
        #expect(device.articles.map(\.id) == [items[0].item.id])
        #expect(device.hasLeftoverTemp)  // only incoming.tmp is left of the second article
        #expect(device.article(items[1].item.id) == nil)
        #expect(!transport.isConnected)

        // While disconnected, a session fails at once and changes nothing.
        let offline = await SyncSession(transport: transport, source: source, config: fastConfig()).run()
        #expect(offline.error == .disconnected)
        #expect(offline.device == nil)

        // Reconnect: the next session starts from the device's LIST and sends what is missing.
        transport.reconnect()
        let second = await SyncSession(transport: transport, source: source, config: fastConfig()).run()
        #expect(second.completed, "\(String(describing: second.error))")
        #expect(second.listing.map(\.id) == [items[0].item.id])
        #expect(second.uploaded == [items[1].item.id, items[2].item.id])
        #expect(second.bytesSent == 49_000)  // the interrupted article is sent again from the start
        #expect(!device.hasLeftoverTemp)
        for (item, data) in items { #expect(device.article(item.id)?.data == data) }
        #expect(device.violations.isEmpty, "\(device.violations)")
        #expect(source.uploaded == items.map(\.item.id))
    }

    @Test func droppedConnectionAtEveryStage() async throws {
        // Cut the link after N data bytes for many N; the follow-up session must always finish the job.
        let items = [item(1, size: 5_000), item(2, size: 9_500)]
        for cut in stride(from: 1, through: 14_500, by: 1_317) {
            let device = FakeDevice()
            let transport = FakeDeviceTransport(device: device, attMTU: 100)
            let source = StaticSyncSource(items: items)
            transport.dropConnection(afterDataBytes: cut)
            let first = await SyncSession(transport: transport, source: source, config: fastConfig()).run()
            #expect(first.error == .disconnected, "cut at \(cut)")
            transport.reconnect()
            let second = await SyncSession(transport: transport, source: source, config: fastConfig()).run()
            #expect(second.completed, "cut at \(cut): \(String(describing: second.error))")
            #expect(Set(first.uploaded + second.uploaded) == Set(items.map(\.item.id)), "cut at \(cut)")
            for (item, data) in items { #expect(device.article(item.id)?.data == data, "cut at \(cut)") }
            #expect(device.violations.isEmpty, "cut at \(cut): \(device.violations)")
        }
    }

    @Test func checksumFailureIsRetriedOnce() async throws {
        let items = [item(1, size: 10_000), item(2, size: 3_000)]
        let device = FakeDevice()
        device.corruptNextTransfers(1)
        let transport = FakeDeviceTransport(device: device)
        let log = LogCollector()
        let report = await SyncSession(transport: transport, source: StaticSyncSource(items: items), config: fastConfig(), log: { log.add($0) }).run()

        #expect(report.completed)
        #expect(report.uploaded == items.map(\.item.id))
        #expect(report.failures.isEmpty)
        #expect(report.bytesSent == 10_000 * 2 + 3_000)
        #expect(device.receivedTypes.filter { $0 == .putBegin }.count == 3)
        #expect(device.article(items[0].item.id)?.data == items[0].data)
        #expect(log.all.contains { $0.contains("PUT_RESULT checksum mismatch") })
        #expect(device.violations.isEmpty)
    }

    @Test func persistentChecksumFailureIsReportedAndTheSessionGoesOn() async throws {
        let items = [item(1, size: 10_000), item(2, size: 3_000)]
        let device = FakeDevice()
        device.corruptNextTransfers(2)
        let transport = FakeDeviceTransport(device: device)
        let source = StaticSyncSource(items: items)
        let report = await SyncSession(transport: transport, source: source, config: fastConfig()).run()

        #expect(report.completed)
        #expect(report.failures == [SyncFailure(id: items[0].item.id, reason: "checksum mismatch")])
        #expect(report.uploaded == [items[1].item.id])
        #expect(device.article(items[0].item.id) == nil)
        #expect(device.hasLeftoverTemp == false)  // overwritten by the next PUT_BEGIN
        #expect(source.uploaded == [items[1].item.id])
        #expect(!device.radioOn)

        // The article is still missing on the device, so the next session sends it.
        transport.reconnect()
        let next = await SyncSession(transport: transport, source: source, config: fastConfig()).run()
        #expect(next.uploaded == [items[0].item.id])
    }

    @Test func corruptionInTransitIsCaughtByTheDeviceCRC() async throws {
        // Here the phone itself sends a wrong byte (the CRC in PUT_BEGIN is of the true file).
        final class Corrupting: SyncTransport, @unchecked Sendable {
            let inner: FakeDeviceTransport
            private let lock = NSLock()
            private var remaining = 1
            init(_ inner: FakeDeviceTransport) { self.inner = inner }
            func maxWriteLength(withResponse: Bool) async -> Int { await inner.maxWriteLength(withResponse: withResponse) }
            func send(_ frame: Data, withResponse: Bool) async throws {
                var frame = frame
                let corrupt: Bool = lock.withLock {
                    guard frame.first == FrameType.putData.rawValue, frame.count > 5, remaining > 0 else { return false }
                    remaining -= 1
                    return true
                }
                if corrupt { frame[frame.startIndex + 5] ^= 0x01 }
                try await inner.send(frame, withResponse: withResponse)
            }
            func receive(timeout: Duration) async throws -> Data { try await inner.receive(timeout: timeout) }
        }
        let one = item(1, size: 20_000)
        let device = FakeDevice()
        let transport = Corrupting(FakeDeviceTransport(device: device))
        let report = await SyncSession(transport: transport, source: StaticSyncSource(items: [one]), config: fastConfig()).run()
        #expect(report.completed)
        #expect(report.uploaded == [one.item.id])
        #expect(device.receivedTypes.filter { $0 == .putBegin }.count == 2)
        #expect(device.article(one.item.id)?.data == one.data)
    }

    @Test func fullDeviceSkipsUploadsButStillDeletes() async throws {
        let items = [item(1, size: 30_000), item(2, size: 100)]
        let retired = ArticleID(canonicalURL: "https://example.com/p/retired")
        let device = FakeDevice()
        device.seed(id: retired)
        device.setFreeBytes(10_000)
        let transport = FakeDeviceTransport(device: device)
        let report = await SyncSession(transport: transport, source: StaticSyncSource(items: items, deletes: [retired]), config: fastConfig()).run()

        #expect(report.completed)
        #expect(report.deviceFull)
        #expect(report.uploaded.isEmpty)
        #expect(report.failures == [SyncFailure(id: items[0].item.id, reason: "no space")])
        #expect(report.deleted == [retired])
        #expect(device.receivedTypes == [.hello, .list, .putBegin, .delete, .bye])
    }

    @Test func busyDeviceEndsTheSession() async throws {
        let device = FakeDevice()
        device.forcePutReady([.busy])
        let transport = FakeDeviceTransport(device: device)
        let report = await SyncSession(transport: transport, source: StaticSyncSource(items: [item(1, size: 100)]), config: fastConfig()).run()
        #expect(report.error == .deviceBusy)
        #expect(report.uploaded.isEmpty)
        #expect(device.receivedTypes == [.hello, .list, .putBegin, .bye])
    }

    @Test func otherPutReadyFailuresSkipTheArticle() async throws {
        let items = [item(1, size: 100), item(2, size: 100)]
        let device = FakeDevice()
        device.forcePutReady([.storageError])
        let transport = FakeDeviceTransport(device: device)
        let report = await SyncSession(transport: transport, source: StaticSyncSource(items: items), config: fastConfig()).run()
        #expect(report.completed)
        #expect(report.failures == [SyncFailure(id: items[0].item.id, reason: "storage error")])
        #expect(report.uploaded == [items[1].item.id])
    }

    @Test func versionMismatchStopsBeforeAnythingElse() async throws {
        let device = FakeDevice()
        device.setProtocolVersion(2)
        let transport = FakeDeviceTransport(device: device)
        let report = await SyncSession(transport: transport, source: StaticSyncSource(items: [item(1, size: 100)]), config: fastConfig()).run()
        #expect(report.error == .versionMismatch(device: 2))
        #expect(report.device?.version == 2)
        #expect(device.receivedTypes == [.hello, .bye])
    }

    @Test func silentDeviceTimesOut() async throws {
        let device = FakeDevice()
        let transport = FakeDeviceTransport(device: device)
        transport.muteDevice(true)
        var config = fastConfig()
        config.helloTimeout = .milliseconds(100)
        let clock = ContinuousClock()
        let started = clock.now
        let report = await SyncSession(transport: transport, source: StaticSyncSource(), config: config).run()
        let elapsed = clock.now - started
        #expect(report.error == .timeout("HELLO_ACK"))
        #expect(elapsed >= .milliseconds(100))
    }

    @Test func listIsReassembledFromManyNotifications() async throws {
        var config = FakeDevice.Config()
        config.maxNotificationLength = 20  // ATT MTU 23: two 9-byte items per notification
        let device = FakeDevice(config: config)
        var expected: [ListItem] = []
        for n in 0..<301 {
            let id = ArticleID(canonicalURL: "https://example.com/seeded/\(n)")
            device.seed(id: id, read: n % 3 == 0)
            expected.append(ListItem(id: id, read: n % 3 == 0))
        }
        let transport = FakeDeviceTransport(device: device, attMTU: 23)
        let report = await SyncSession(transport: transport, source: StaticSyncSource(), config: fastConfig()).run()
        #expect(report.completed)
        #expect(report.listing == expected)
        #expect(device.receivedTypes == [.hello, .list, .bye])
    }

    @Test func metadataIsMadeSafeForTheDeviceIndex() async throws {
        let id = ArticleID(canonicalURL: "https://example.com/p/long")
        let nasty = SyncItem(
            id: id, time: fixedNow, source: "Tab\tSeparated\nSource " + String(repeating: "s", count: 300),
            title: "Line one\nline two\ttabbed " + String(repeating: "é", count: 400), author: String(repeating: "Ä", count: 200))
        let device = FakeDevice()
        let transport = FakeDeviceTransport(device: device)
        let report = await SyncSession(transport: transport, source: StaticSyncSource(items: [(nasty, payload(500, seed: 9))]), config: fastConfig()).run()
        #expect(report.completed, "\(String(describing: report.error))")
        let stored = try #require(device.article(id))
        for field in [stored.source, stored.title, stored.author] {
            #expect(!field.contains("\t") && !field.contains("\n"))
            #expect(field.utf8.count <= 255)
            #expect(!field.isEmpty)
        }
        #expect(stored.title.hasPrefix("Line one line two tabbed é"))
        #expect(stored.source.hasPrefix("Tab Separated Source s"))
        #expect(transport.oversizedWrites == 0)  // PUT_BEGIN fitted in one write
    }

    @Test func missingPayloadIsAFailureNotACrash() async throws {
        struct Broken: SyncDataSource {
            let good: (item: SyncItem, data: Data)
            let bad: SyncItem
            func plan(device: HelloAck, listing: [ListItem]) async throws -> SyncPlan { SyncPlan(puts: [bad, good.item]) }
            func payload(for id: ArticleID) async throws -> Data {
                if id == good.item.id { return good.data }
                throw ArticleStoreError.missingFile(id)
            }
            func didUpload(_ id: ArticleID) async {}
            func didDelete(_ id: ArticleID) async {}
        }
        let good = item(1, size: 100)
        let bad = item(2, size: 100).item
        let device = FakeDevice()
        let report = await SyncSession(transport: FakeDeviceTransport(device: device), source: Broken(good: good, bad: bad), config: fastConfig()).run()
        #expect(report.completed)
        #expect(report.uploaded == [good.item.id])
        #expect(report.failures.map(\.id) == [bad.id])
    }

    // MARK: Misbehaving devices

    @Test func listCountMismatchIsAProtocolViolation() async throws {
        let id = ArticleID(canonicalURL: "https://example.com/x")
        let transport = ScriptedTransport { frame in
            switch frame {
            case .hello: return [enc(.helloAck(HelloAck(version: 1, batteryPercent: 50, freeSpaceMB: 1, firmwareVersion: "x")))]
            case .list: return [enc(.listItems([ListItem(id: id, read: false)])), enc(.listEnd(total: 2))]
            default: return []
            }
        }
        let report = await SyncSession(transport: transport, source: StaticSyncSource(), config: fastConfig()).run()
        guard case .protocolViolation = report.error else {
            Issue.record("expected a protocol violation, got \(String(describing: report.error))")
            return
        }
        #expect(transport.sent == [.hello(version: 1, unixTime: 1_794_744_000), .list, .bye])
    }

    @Test func garbageAndStrayFramesAreIgnored() async throws {
        let one = item(1, size: 300)
        let transport = ScriptedTransport { frame in
            switch frame {
            case .hello:
                return [Data(), Data([0x7F, 1, 2]), Data([0x81]), enc(.putProgress(5)), enc(.helloAck(HelloAck(version: 1, batteryPercent: 50, freeSpaceMB: 1, firmwareVersion: "x")))]
            case .list: return [enc(.deleteResult(.ok)), enc(.listEnd(total: 0))]
            case .putBegin: return [enc(.listEnd(total: 9)), enc(.putReady(.ok))]
            case .putEnd: return [enc(.putProgress(300)), enc(.putProgress(300)), enc(.putResult(.ok))]
            default: return []
            }
        }
        let report = await SyncSession(transport: transport, source: StaticSyncSource(items: [one]), config: fastConfig()).run()
        #expect(report.completed, "\(String(describing: report.error))")
        #expect(report.uploaded == [one.item.id])
    }

    @Test func impossibleProgressIsAProtocolViolation() async throws {
        let one = item(1, size: 300)
        let transport = ScriptedTransport { frame in
            switch frame {
            case .hello: return [enc(.helloAck(HelloAck(version: 1, batteryPercent: 50, freeSpaceMB: 1, firmwareVersion: "x")))]
            case .list: return [enc(.listEnd(total: 0))]
            case .putBegin: return [enc(.putReady(.ok))]
            case .putEnd: return [enc(.putProgress(301)), enc(.putResult(.ok))]
            default: return []
            }
        }
        let report = await SyncSession(transport: transport, source: StaticSyncSource(items: [one]), config: fastConfig()).run()
        #expect(report.error == .protocolViolation("PUT_PROGRESS 301 is outside 0…300"))
        #expect(report.uploaded.isEmpty)
    }

    @Test func deviceAbortingMidTransferIsHandled() async throws {
        // The device reports a storage error while data is still flowing.
        let big = item(1, size: 50_000)
        let small = item(2, size: 200)
        let state = LogCollector()
        let transport = ScriptedTransport { frame in
            switch frame {
            case .hello: return [enc(.helloAck(HelloAck(version: 1, batteryPercent: 50, freeSpaceMB: 1, firmwareVersion: "x")))]
            case .list: return [enc(.listEnd(total: 0))]
            case .putBegin(let begin):
                state.add(begin.id.hex)
                return [enc(.putReady(.ok))]
            case .putData:
                // First transfer: fail it. Second transfer: accept quietly.
                if state.all.count == 1, !state.all.contains("failed") {
                    state.add("failed")
                    return [enc(.putResult(.storageError))]
                }
                return []
            case .putEnd: return [enc(.putResult(.ok))]
            default: return []
            }
        }
        let report = await SyncSession(transport: transport, source: StaticSyncSource(items: [big, small]), config: fastConfig()).run()
        #expect(report.completed, "\(String(describing: report.error))")
        #expect(report.failures == [SyncFailure(id: big.item.id, reason: "storage error")])
        #expect(report.uploaded == [small.item.id])
        // The phone stopped sending the failed article at the window, and never sent PUT_END for it.
        #expect(transport.sent.filter { $0 == .putEnd }.count == 1)
    }
}

@Suite struct StoreBackedSyncTests {
    /// The whole life of an article: fetched, loaded, synced, read on the device, taken off.
    @Test func lifecycle() async throws {
        let directory = try makeTempDirectory("paperboy-sync")
        defer { try? FileManager.default.removeItem(at: directory) }
        let day: TimeInterval = 86_400
        let store = try ArticleStore(directory: directory)
        let articles = DemoArticles.articles
        for article in articles { try await store.add(article, fetchedAt: fixedNow) }

        let device = FakeDevice()
        let transport = FakeDeviceTransport(device: device)

        func sync(at now: Date) async -> SyncReport {
            transport.reconnect()
            var config = fastConfig()
            config.now = { now }
            let source = ArticleStoreSyncSource(store: store, now: { now })
            return await SyncSession(transport: transport, source: source, config: config).run()
        }

        // Day 0: nothing was asked for, so nothing goes to the reader.
        let untouched = await sync(at: fixedNow)
        #expect(untouched.completed && untouched.uploaded.isEmpty && device.articles.isEmpty)

        // Two are loaded and one locked: all three go, newest first.
        try await store.setLoad(articles[0].id, .load)
        try await store.setLoad(articles[1].id, .load)
        try await store.setLoad(articles[2].id, .lock)
        let first = await sync(at: fixedNow)
        #expect(first.completed, "\(String(describing: first.error))")
        #expect(first.uploaded == [articles[2].id, articles[1].id, articles[0].id])
        #expect(await store.all().allSatisfy(\.onDevice))
        #expect(device.articles.count == 3)
        for article in articles {
            #expect(device.article(article.id)?.data == (try EpubBuilder.build(article)))
            #expect(device.article(article.id)?.title == article.title)
        }

        // Nothing to do the second time.
        let idle = await sync(at: fixedNow.addingTimeInterval(3600))
        #expect(idle.completed && idle.uploaded.isEmpty && idle.deleted.isEmpty)
        #expect(device.receivedTypes.suffix(3) == [.hello, .list, .bye])

        // Day 1: a loaded and the locked article are read. The loaded one comes off in the very
        // sync that learns of it; the locked one stays.
        device.markRead(articles[0].id)
        device.markRead(articles[2].id)
        let dayOne = await sync(at: fixedNow.addingTimeInterval(1 * day))
        #expect(dayOne.completed)
        #expect(dayOne.deleted == [articles[0].id])
        let readArticle = try #require(await store.article(articles[0].id))
        #expect(readArticle.read && readArticle.load == .off && !readArticle.onDevice)
        #expect(readArticle.readAt == fixedNow.addingTimeInterval(1 * day))
        #expect(device.article(articles[0].id) == nil)
        #expect(device.articles.count == 2)

        // Unlocking the read one takes it off too; the unread loaded one is still there.
        try await store.setLoad(articles[2].id, .off)
        let dayTwo = await sync(at: fixedNow.addingTimeInterval(2 * day))
        #expect(dayTwo.deleted == [articles[2].id])
        #expect(device.articles.map(\.id) == [articles[1].id])

        // An article the phone has never heard of (put there by another tool) is removed.
        let stranger = ArticleID(canonicalURL: "https://elsewhere.example/x")
        device.seed(id: stranger, data: Data("x".utf8))
        let dayThree = await sync(at: fixedNow.addingTimeInterval(3 * day))
        #expect(dayThree.deleted == [stranger])

        // A loaded article is kept on the reader past the list's 14 days, until it is read.
        let dayThirty = await sync(at: fixedNow.addingTimeInterval(30 * day))
        #expect(dayThirty.completed && dayThirty.deleted.isEmpty)
        #expect(device.articles.map(\.id) == [articles[1].id])
        #expect(device.violations.isEmpty, "\(device.violations)")
    }

    @Test func interruptedStoreSyncResumes() async throws {
        let directory = try makeTempDirectory("paperboy-sync")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ArticleStore(directory: directory)
        for article in DemoArticles.articles { try await store.add(article, fetchedAt: fixedNow, load: .load) }
        let device = FakeDevice()
        let transport = FakeDeviceTransport(device: device)
        let source = ArticleStoreSyncSource(store: store, now: { fixedNow })

        transport.dropConnection(afterDataBytes: 3_000)
        let first = await SyncSession(transport: transport, source: source, config: fastConfig()).run()
        #expect(first.error == .disconnected)
        let onDeviceAfterDrop = await store.all().filter(\.onDevice).map(\.id)
        #expect(onDeviceAfterDrop == first.uploaded)

        transport.reconnect()
        let second = await SyncSession(transport: transport, source: source, config: fastConfig()).run()
        #expect(second.completed)
        #expect(await store.all().allSatisfy(\.onDevice))
        #expect(device.articles.count == 3)
        #expect(first.uploaded.count + second.uploaded.count == 3)
    }
}

@Suite struct FrameInboxTests {
    @Test func deliversInOrder() async throws {
        let inbox = FrameInbox()
        for n in 0..<50 { inbox.push(Data([UInt8(n)])) }
        for n in 0..<50 { #expect(try await inbox.next(timeout: .seconds(1)) == Data([UInt8(n)])) }
    }

    @Test func wakesAWaiter() async throws {
        let inbox = FrameInbox()
        let reader = Task { try await inbox.next(timeout: .seconds(5)) }
        try await Task.sleep(for: .milliseconds(30))
        inbox.push(Data([7]))
        #expect(try await reader.value == Data([7]))
    }

    @Test func timesOut() async {
        let inbox = FrameInbox()
        await #expect(throws: SyncError.timeout("a frame")) { try await inbox.next(timeout: .milliseconds(30)) }
        await #expect(throws: SyncError.timeout("x")) { try await inbox.next(timeout: .zero, waitingFor: "x") }
        // A frame that arrives later is still delivered to the next reader.
        inbox.push(Data([1]))
        #expect((try? await inbox.next(timeout: .milliseconds(30))) == Data([1]))
    }

    @Test func closeDeliversQueuedFramesFirst() async throws {
        let inbox = FrameInbox()
        inbox.push(Data([1]))
        inbox.close(.disconnected)
        inbox.push(Data([2]))  // after close: dropped
        #expect(try await inbox.next(timeout: .seconds(1)) == Data([1]))
        await #expect(throws: SyncError.disconnected) { try await inbox.next(timeout: .seconds(1)) }
        inbox.reset()
        inbox.push(Data([3]))
        #expect(try await inbox.next(timeout: .seconds(1)) == Data([3]))
    }

    @Test func closeWakesAWaiter() async throws {
        let inbox = FrameInbox()
        let reader = Task { try await inbox.next(timeout: .seconds(5)) }
        try await Task.sleep(for: .milliseconds(30))
        inbox.close(.disconnected)
        await #expect(throws: SyncError.disconnected) { try await reader.value }
    }

    @Test func cancellationWakesAWaiter() async throws {
        let inbox = FrameInbox()
        let reader = Task { try await inbox.next(timeout: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(30))
        reader.cancel()
        await #expect(throws: SyncError.cancelled) { try await reader.value }
    }
}

@Suite struct FakeDeviceTests {
    /// The device side on its own, frame by frame: the reference for the firmware.
    @Test func conversationByBytes() throws {
        let device = FakeDevice()
        func exchange(_ frame: Frame) throws -> [Frame] {
            try device.receive(try frame.encode()).map { try Frame.decode($0) }
        }
        let body = payload(9000, seed: 3)
        let id = ArticleID(canonicalURL: "https://example.com/p/ref")
        let begin = PutBegin(id: id, size: 9000, crc32: CRC32.checksum(body), time: 1_794_744_000, source: "S", title: "T", author: "A")

        #expect(try exchange(.hello(version: 1, unixTime: 1_794_744_000))
            == [.helloAck(HelloAck(version: 1, batteryPercent: 87, freeSpaceMB: 512, firmwareVersion: "paperboy-fake-1.0"))])
        #expect(try exchange(.list) == [.listEnd(total: 0)])
        #expect(try exchange(.putBegin(begin)) == [.putReady(.ok)])
        // 4000 + 4000 + 1000 bytes: progress after the second chunk (8000 ≥ 4096 past 0), not after the first.
        #expect(try exchange(.putData(body.subdata(in: 0..<4000))) == [])
        #expect(try exchange(.putData(body.subdata(in: 4000..<8000))) == [.putProgress(8000)])
        #expect(try exchange(.putData(body.subdata(in: 8000..<9000))) == [.putProgress(9000)])  // once at the end
        #expect(try exchange(.putEnd) == [.putResult(.ok)])
        #expect(try exchange(.list) == [.listItems([ListItem(id: id, read: false)]), .listEnd(total: 1)])
        #expect(try exchange(.putBegin(begin)) == [.putReady(.exists)])
        #expect(try exchange(.putData(Data([1]))) == [])  // no transfer open: ignored
        #expect(try exchange(.putEnd) == [.putResult(.badRequest)])
        #expect(try exchange(.delete(id)) == [.deleteResult(.ok)])
        #expect(try exchange(.delete(id)) == [.deleteResult(.ok)])
        #expect(try exchange(.list) == [.listEnd(total: 0)])
        #expect(device.radioOn)
        #expect(try exchange(.bye) == [])
        #expect(!device.radioOn)
    }

    @Test func rejectsWrongSizeAndWrongCRC() throws {
        let device = FakeDevice()
        func exchange(_ frame: Frame) throws -> [Frame] {
            try device.receive(try frame.encode()).map { try Frame.decode($0) }
        }
        let id = ArticleID(canonicalURL: "https://example.com/p/bad")
        let body = Data("hello world".utf8)
        // Wrong CRC.
        #expect(try exchange(.putBegin(PutBegin(id: id, size: 11, crc32: 1, time: 0, source: "", title: "", author: ""))) == [.putReady(.ok)])
        #expect(try exchange(.putData(body)) == [.putProgress(11)])
        #expect(try exchange(.putEnd) == [.putResult(.checksumMismatch)])
        // Short file.
        #expect(try exchange(.putBegin(PutBegin(id: id, size: 12, crc32: CRC32.checksum(body), time: 0, source: "", title: "", author: ""))) == [.putReady(.ok)])
        #expect(try exchange(.putData(body)) == [])
        #expect(try exchange(.putEnd) == [.putResult(.checksumMismatch)])
        // Too much data: nothing is said until PUT_END.
        #expect(try exchange(.putBegin(PutBegin(id: id, size: 5, crc32: 0, time: 0, source: "", title: "", author: ""))) == [.putReady(.ok)])
        #expect(try exchange(.putData(body)) == [])
        #expect(try exchange(.putData(body)) == [])
        #expect(try exchange(.putEnd) == [.putResult(.storageError)])
        // Empty file.
        #expect(try exchange(.putBegin(PutBegin(id: id, size: 0, crc32: 0, time: 0, source: "", title: "", author: ""))) == [.putReady(.badRequest)])
        // No room.
        device.setFreeBytes(10)
        #expect(try exchange(.putBegin(PutBegin(id: id, size: 11, crc32: 0, time: 0, source: "", title: "", author: ""))) == [.putReady(.noSpace)])
        #expect(device.articles.isEmpty)
    }
}
