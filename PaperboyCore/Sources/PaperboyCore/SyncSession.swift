import Foundation

/// One article offered to the device.
public struct SyncItem: Sendable, Equatable {
    public var id: ArticleID
    /// The article's time; sent as unix seconds, the device lists newest first.
    public var time: Date
    public var source: String
    public var title: String
    public var author: String

    public init(id: ArticleID, time: Date, source: String, title: String, author: String) {
        self.id = id
        self.time = time
        self.source = source
        self.title = title
        self.author = author
    }
}

public struct SyncTouch: Sendable, Equatable {
    public var id: ArticleID
    public var nonce: UInt32
    public init(id: ArticleID, nonce: UInt32) { self.id = id; self.nonce = nonce }
}

public struct SyncPlan: Sendable, Equatable {
    /// Articles the device should have, in upload order. Ones the device already lists are
    /// skipped by the session.
    public var puts: [SyncItem]
    /// Articles the phone has retired. Only ones the device lists are deleted.
    public var touches: [SyncTouch]
    public var deletes: [ArticleID]

    public init(puts: [SyncItem] = [], deletes: [ArticleID] = [], touches: [SyncTouch] = []) {
        self.touches = touches
        self.puts = puts
        self.deletes = deletes
    }
}

/// Where a session gets its work from, and where it reports progress as it goes, so that a
/// session cut short by a disconnect loses nothing it had finished.
public protocol SyncDataSource: Sendable {
    /// Called once per session, after HELLO and LIST.
    func plan(device: HelloAck, listing: [ListItem]) async throws -> SyncPlan
    /// The EPUB bytes of an article in the plan.
    func payload(for id: ArticleID) async throws -> Data
    /// The device confirmed it stored the article (or said it already had it).
    func didUpload(_ id: ArticleID) async
    /// The device confirmed the article is gone.
    func didDelete(_ id: ArticleID) async
    func didTouch(_ touch: SyncTouch) async
}

public extension SyncDataSource { func didTouch(_ touch: SyncTouch) async {} }

public struct SyncConfig: Sendable {
    public var helloTimeout: Duration = .seconds(5)
    public var listTimeout: Duration = .seconds(10)
    public var putReadyTimeout: Duration = .seconds(10)
    /// Longest wait for a PUT_PROGRESS while the flow-control window is full.
    public var progressTimeout: Duration = .seconds(10)
    /// Longest wait for PUT_RESULT after PUT_END (the device checks the CRC and renames the file).
    public var putResultTimeout: Duration = .seconds(30)
    public var deleteTimeout: Duration = .seconds(10)
    public var flowControlWindow: Int = SyncProtocol.flowControlWindow
    /// How many times an article is sent again after a checksum mismatch.
    public var checksumRetries: Int = 1
    public var now: @Sendable () -> Date = { Date() }

    public init() {}
}

public struct SyncFailure: Sendable, Equatable {
    public var id: ArticleID
    public var reason: String
}

public struct SyncReport: Sendable {
    public var device: HelloAck?
    /// What the device listed at the start of the session.
    public var listing: [ListItem] = []
    public var uploaded: [ArticleID] = []
    /// Offered, but the device answered "exists".
    public var alreadyPresent: [ArticleID] = []
    public var deleted: [ArticleID] = []
    public var bumped: [ArticleID] = []
    public var failures: [SyncFailure] = []
    public var bytesSent: Int = 0
    /// The device ran out of space; remaining uploads were skipped.
    public var deviceFull = false
    /// nil when the session ran to BYE. Otherwise why it stopped; everything listed above
    /// still happened, and the next session picks up where this one left off.
    public var error: SyncError?

    public var completed: Bool { error == nil }
}

public typealias SyncLogger = @Sendable (String) -> Void

/// The phone side of one sync session:
/// HELLO → LIST → PUT_BEGIN / PUT_DATA… / PUT_END for each article the device lacks →
/// DELETE for each retired article → BYE.
///
/// Resume safety: nothing is remembered between sessions except what the data source records
/// through `didUpload` / `didDelete`. Every session starts from the device's own LIST, so after
/// a dropped connection the next session simply sends what is still missing. A partly
/// transferred article is sent again from the start (the device overwrites `incoming.tmp`).
public struct SyncSession: Sendable {
    public let transport: any SyncTransport
    public let source: any SyncDataSource
    public var config: SyncConfig
    public var log: SyncLogger?

    public init(transport: any SyncTransport, source: any SyncDataSource, config: SyncConfig = SyncConfig(), log: SyncLogger? = nil) {
        self.transport = transport
        self.source = source
        self.config = config
        self.log = log
    }

    public func run() async -> SyncReport {
        var report = SyncReport()
        do {
            try await runSession(&report)
        } catch let error as SyncError {
            report.error = error
        } catch is CancellationError {
            report.error = .cancelled
        } catch {
            report.error = .transport(String(describing: error))
        }
        if let error = report.error {
            log?("session stopped: \(error)")
            // Be polite if the link is still up; the device turns its radio off on BYE.
            if error != .disconnected, error != .cancelled {
                try? await send(.bye)
            }
        }
        return report
    }

    // MARK: Session

    private func runSession(_ report: inout SyncReport) async throws {
        // HELLO
        let unixTime = UInt32(clamping: Int64(config.now().timeIntervalSince1970))
        try await send(.hello(version: SyncProtocol.version, unixTime: unixTime))
        let ack: HelloAck = try await expect("HELLO_ACK", timeout: config.helloTimeout) { frame in
            if case .helloAck(let ack) = frame { return ack }
            return nil
        }
        report.device = ack
        guard ack.version == SyncProtocol.version || ack.version == 1 else { throw SyncError.versionMismatch(device: ack.version) }

        // LIST
        try await send(.list)
        var listing: [ListItem] = []
        let total: UInt16 = try await expect("LIST_END", timeout: config.listTimeout) { frame in
            switch frame {
            case .listItems(let items):
                listing.append(contentsOf: items)
                return nil
            case .listEnd(let total):
                return total
            default:
                return nil
            }
        }
        guard Int(total) == listing.count else {
            throw SyncError.protocolViolation("LIST_END says \(total) articles but \(listing.count) were listed")
        }
        report.listing = listing
        var onDevice = Set(listing.map(\.id))

        // Plan
        let plan: SyncPlan
        do {
            plan = try await source.plan(device: ack, listing: listing)
        } catch let error as SyncError {
            throw error
        } catch {
            throw SyncError.dataSource(String(describing: error))
        }
        log?("plan: \(plan.puts.count) article(s) offered, \(plan.deletes.count) to delete, device has \(listing.count)")

        // PUT
        for item in plan.puts {
            if onDevice.contains(item.id) { continue }
            if report.deviceFull { break }
            let data: Data
            do {
                data = try await source.payload(for: item.id)
            } catch {
                log?("skipping \(item.id): \(error)")
                report.failures.append(SyncFailure(id: item.id, reason: "no data: \(error)"))
                continue
            }
            switch try await put(item, data: data, report: &report) {
            case .stored:
                onDevice.insert(item.id)
                report.uploaded.append(item.id)
                await source.didUpload(item.id)
            case .exists:
                onDevice.insert(item.id)
                report.alreadyPresent.append(item.id)
                await source.didUpload(item.id)
            case .noSpace:
                report.deviceFull = true
                report.failures.append(SyncFailure(id: item.id, reason: SyncStatus.noSpace.description))
            case .failed(let status):
                report.failures.append(SyncFailure(id: item.id, reason: status.description))
            }
        }

        // TOUCH changes priority only. Old firmware keeps these requests queued.
        for touch in plan.touches where onDevice.contains(touch.id) && !plan.deletes.contains(touch.id) {
            guard ack.version >= 2 else {
                report.failures.append(SyncFailure(id: touch.id, reason: "update reader firmware to sync bumps"))
                continue
            }
            try await send(.touch(touch))
            let status: SyncStatus = try await expect("TOUCH_RESULT", timeout: config.putReadyTimeout) { frame in
                if case .touchResult(let status) = frame { return status }
                return nil
            }
            if status == .ok {
                report.bumped.append(touch.id)
                await source.didTouch(touch)
            } else { report.failures.append(SyncFailure(id: touch.id, reason: "bump: \(status)")) }
        }

        // DELETE
        for id in plan.deletes where onDevice.contains(id) {
            try await send(.delete(id))
            let status: SyncStatus = try await expect("DELETE_RESULT", timeout: config.deleteTimeout) { frame in
                if case .deleteResult(let status) = frame { return status }
                return nil
            }
            if status == .ok {
                onDevice.remove(id)
                report.deleted.append(id)
                await source.didDelete(id)
            } else if status == .busy {
                throw SyncError.deviceBusy
            } else {
                report.failures.append(SyncFailure(id: id, reason: "delete: \(status)"))
            }
        }

        // BYE. The device turns the radio off, so a failure here is not an error.
        do { try await send(.bye) } catch { log?("BYE not delivered: \(error)") }
    }

    private enum PutOutcome {
        case stored
        case exists
        case noSpace
        case failed(SyncStatus)
    }

    private func put(_ item: SyncItem, data: Data, report: inout SyncReport) async throws -> PutOutcome {
        guard data.count <= Int(UInt32.max) else { return .failed(.badRequest) }
        let window = max(1, config.flowControlWindow)
        let begin = await makePutBegin(item, data: data)
        var attempt = 0
        while true {
            attempt += 1
            try await send(.putBegin(begin))
            let ready: SyncStatus = try await expect("PUT_READY", timeout: config.putReadyTimeout) { frame in
                if case .putReady(let status) = frame { return status }
                return nil
            }
            switch ready {
            case .ok: break
            case .exists: return .exists
            case .noSpace: return .noSpace
            case .busy: throw SyncError.deviceBusy
            default: return .failed(ready)
            }

            // PUT_DATA, never more than `window` bytes past the last PUT_PROGRESS value.
            let chunkSize = min(window, max(1, await transport.maxWriteLength(withResponse: false) - 1))
            var sent = 0
            var acknowledged = 0
            var earlyResult: SyncStatus?
            var stalled = false
            sending: while sent < data.count {
                let count = min(chunkSize, data.count - sent)
                while sent + count - acknowledged > window {
                    let frame: Frame
                    do {
                        frame = try await receive(config.progressTimeout, waitingFor: "PUT_PROGRESS (sent \(sent), acknowledged \(acknowledged))")
                    } catch SyncError.timeout {
                        // The window is full and the device has gone quiet. It may have given up on
                        // this file without saying so (a write error is only reported after
                        // PUT_END), so ask for the verdict instead of abandoning the session.
                        log?("no PUT_PROGRESS with the window full (sent \(sent), acknowledged \(acknowledged)); ending this transfer")
                        stalled = true
                        break sending
                    }
                    switch frame {
                    case .putProgress(let stored):
                        acknowledged = try checkedProgress(stored, sent: sent, previous: acknowledged)
                    case .putResult(let status):
                        earlyResult = status  // the device gave up mid-transfer
                        break sending
                    default:
                        log?("ignoring unexpected \(frame.logDescription) during transfer")
                    }
                }
                let start = data.startIndex + sent
                try await send(.putData(data.subdata(in: start..<(start + count))), withResponse: false)
                sent += count
                report.bytesSent += count
            }

            let result: SyncStatus
            if let earlyResult {
                result = earlyResult
            } else {
                try await send(.putEnd)
                result = try await expect("PUT_RESULT", timeout: config.putResultTimeout) { frame in
                    switch frame {
                    case .putResult(let status): return status
                    case .putProgress(let stored):
                        acknowledged = try checkedProgress(stored, sent: sent, previous: acknowledged)
                        return nil
                    default: return nil
                    }
                }
                if stalled, result == .ok {
                    throw SyncError.protocolViolation("PUT_RESULT ok for a transfer that was cut short at \(sent) of \(data.count) bytes")
                }
            }
            switch result {
            case .ok:
                return .stored
            case .checksumMismatch where attempt <= config.checksumRetries:
                log?("checksum mismatch for \(item.id), sending it again (attempt \(attempt + 1))")
                continue
            case .exists:
                return .exists
            case .noSpace:
                return .noSpace
            case .busy:
                throw SyncError.deviceBusy
            default:
                return .failed(result)
            }
        }
    }

    private func checkedProgress(_ stored: UInt32, sent: Int, previous: Int) throws -> Int {
        let value = Int(stored)
        guard value <= sent, value >= previous else {
            throw SyncError.protocolViolation("PUT_PROGRESS \(value) is outside \(previous)…\(sent)")
        }
        return value
    }

    /// Build PUT_BEGIN, with the strings made safe for the device's tab-separated index and
    /// cut so that the whole frame fits in one write.
    func makePutBegin(_ item: SyncItem, data: Data) async -> PutBegin {
        // Prefer a frame that fits in a single ATT write (MTU − 3), so the device never has to
        // reassemble a long write; fall back to the long-write limit when the MTU is tiny.
        let longLimit = await transport.maxWriteLength(withResponse: true)
        let singleLimit = await transport.maxWriteLength(withResponse: false)
        let maxFrame = singleLimit >= 96 ? min(singleLimit, longLimit) : longLimit
        var room = max(24, maxFrame - SyncProtocol.putBeginFixedBytes)
        let source = SyncText.truncate(SyncText.sanitizeField(item.source), maxBytes: min(48, room / 4, SyncProtocol.maxStringBytes))
        room -= source.utf8.count
        let author = SyncText.truncate(SyncText.sanitizeField(item.author), maxBytes: min(64, room / 3, SyncProtocol.maxStringBytes))
        room -= author.utf8.count
        let title = SyncText.truncate(SyncText.sanitizeField(item.title), maxBytes: min(room, SyncProtocol.maxStringBytes))
        return PutBegin(
            id: item.id,
            size: UInt32(data.count),
            crc32: CRC32.checksum(data),
            time: UInt32(clamping: Int64(item.time.timeIntervalSince1970)),
            source: source,
            title: title,
            author: author)
    }

    // MARK: Frames

    private func send(_ frame: Frame, withResponse: Bool = true) async throws {
        let encoded: Data
        do { encoded = try frame.encode() } catch { throw SyncError.protocolViolation(String(describing: error)) }
        if case .putData = frame {} else { log?("→ \(frame.logDescription)") }
        do {
            try await transport.send(encoded, withResponse: withResponse)
        } catch let error as SyncError {
            throw error
        } catch is CancellationError {
            throw SyncError.cancelled
        } catch {
            throw SyncError.transport(String(describing: error))
        }
    }

    /// The next decodable frame. Frames that do not decode are logged and skipped.
    private func receive(_ timeout: Duration, waitingFor what: String) async throws -> Frame {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while true {
            let remaining = deadline - clock.now
            guard remaining > .zero else { throw SyncError.timeout(what) }
            let raw: Data
            do {
                raw = try await transport.receive(timeout: remaining)
            } catch let error as SyncError {
                if case .timeout = error { throw SyncError.timeout(what) }
                throw error
            } catch is CancellationError {
                throw SyncError.cancelled
            } catch {
                throw SyncError.transport(String(describing: error))
            }
            do {
                let frame = try Frame.decode(raw)
                log?("← \(frame.logDescription)")
                return frame
            } catch {
                log?("← undecodable frame (\(raw.count) bytes): \(error)")
            }
        }
    }

    /// Read frames until `match` returns a value. Frames it returns nil for are skipped.
    private func expect<T>(_ what: String, timeout: Duration, _ match: (Frame) throws -> T?) async throws -> T {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while true {
            let remaining = deadline - clock.now
            guard remaining > .zero else { throw SyncError.timeout(what) }
            let frame = try await receive(remaining, waitingFor: what)
            if let value = try match(frame) { return value }
        }
    }
}

/// A fixed set of articles held in memory; used by the CLI and the tests.
public final class StaticSyncSource: SyncDataSource, @unchecked Sendable {
    private let lock = NSLock()
    private let items: [SyncItem]
    private let payloads: [ArticleID: Data]
    private let deletes: [ArticleID]
    private var uploadedIDs: [ArticleID] = []
    private var deletedIDs: [ArticleID] = []

    public init(items: [(item: SyncItem, data: Data)] = [], deletes: [ArticleID] = []) {
        self.items = items.map(\.item)
        var payloads: [ArticleID: Data] = [:]
        for entry in items { payloads[entry.item.id] = entry.data }
        self.payloads = payloads
        self.deletes = deletes
    }

    public var uploaded: [ArticleID] { lock.withLock { uploadedIDs } }
    public var deleted: [ArticleID] { lock.withLock { deletedIDs } }

    public func plan(device: HelloAck, listing: [ListItem]) async throws -> SyncPlan {
        SyncPlan(puts: items, deletes: deletes)
    }

    public func payload(for id: ArticleID) async throws -> Data {
        guard let data = payloads[id] else { throw ArticleStoreError.unknownArticle(id) }
        return data
    }

    public func didUpload(_ id: ArticleID) async {
        lock.withLock { uploadedIDs.append(id) }
    }

    public func didDelete(_ id: ArticleID) async {
        lock.withLock { deletedIDs.append(id) }
    }
}
