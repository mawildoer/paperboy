import Foundation

/// An in-memory implementation of the DEVICE side of the protocol.
///
/// It exists for the tests, and as executable documentation for the firmware: `receive(_:)` is
/// what the firmware's RX write handler has to do, and the frames it returns are the
/// notifications to send on TX, in order.
///
/// Choices made where DESIGN.md is silent are marked "CHOICE"; they follow what the firmware
/// in `firmware/lib/PhoneSync` did when this was written.
public final class FakeDevice: @unchecked Sendable {
    public struct Config: Sendable {
        public var batteryPercent: UInt8 = 87
        public var freeBytes: Int = 512 * 1024 * 1024
        public var firmwareVersion = "paperboy-fake-1.0"
        /// Largest notification payload (ATT MTU − 3). LIST_ITEMS is split to fit.
        public var maxNotificationLength = 182
        public var progressInterval = SyncProtocol.progressInterval
        public var flowControlWindow = SyncProtocol.flowControlWindow

        public init() {}
    }

    public struct Stored: Sendable, Equatable {
        public var id: ArticleID
        public var data: Data
        public var time: UInt32
        public var source: String
        public var title: String
        public var author: String
        public var read: Bool
    }

    private struct Incoming {
        var begin: PutBegin
        var data = Data()
        var lastReported = 0
        var failed = false
    }

    private let lock = NSLock()
    private var config: Config
    private var stored: [ArticleID: Stored] = [:]
    private var order: [ArticleID] = []
    private var incoming: Incoming?
    /// What `/Articles/incoming.tmp` would hold after an interrupted transfer.
    private var leftoverTemp: Data?
    private var _violations: [String] = []
    private var _radioOn = true
    private var _helloCount = 0
    private var _lastHelloTime: UInt32?
    private var _receivedTypes: [FrameType] = []
    private var corruptTransfers = 0
    private var forcedPutReady: [SyncStatus] = []
    private var _protocolVersion = SyncProtocol.version

    public init(config: Config = Config()) {
        self.config = config
    }

    // MARK: Inspection and test hooks

    /// Things the phone did that the protocol forbids (e.g. overrunning the flow-control window).
    public var violations: [String] { lock.withLock { _violations } }
    /// False after BYE: the device has turned its radio off.
    public var radioOn: Bool { lock.withLock { _radioOn } }
    public var helloCount: Int { lock.withLock { _helloCount } }
    public var lastHelloTime: UInt32? { lock.withLock { _lastHelloTime } }
    /// Types of every frame received, in order.
    public var receivedTypes: [FrameType] { lock.withLock { _receivedTypes } }
    public var articles: [Stored] { lock.withLock { order.compactMap { stored[$0] } } }
    public var hasLeftoverTemp: Bool { lock.withLock { leftoverTemp != nil } }

    public func article(_ id: ArticleID) -> Stored? { lock.withLock { stored[id] } }

    /// Put an article on the "card" directly.
    public func seed(id: ArticleID, data: Data = Data("seed".utf8), time: UInt32 = 0, source: String = "", title: String = "", author: String = "", read: Bool = false) {
        lock.withLock {
            if stored[id] == nil { order.append(id) }
            stored[id] = Stored(id: id, data: data, time: time, source: source, title: title, author: author, read: read)
        }
    }

    /// The user opened an article on the device.
    public func markRead(_ id: ArticleID) {
        lock.withLock { stored[id]?.read = true }
    }

    /// Flip one byte of the next `count` transfers before the CRC check (a write error).
    public func corruptNextTransfers(_ count: Int = 1) {
        lock.withLock { corruptTransfers = count }
    }

    /// Answer the next PUT_BEGINs with these statuses instead of the real ones.
    public func forcePutReady(_ statuses: [SyncStatus]) {
        lock.withLock { forcedPutReady = statuses }
    }

    public func setFreeBytes(_ bytes: Int) {
        lock.withLock { config.freeBytes = bytes }
    }

    public func setProtocolVersion(_ version: UInt8) {
        lock.withLock { _protocolVersion = version }
    }

    /// The phone connected (again): the radio is on and no transfer is in progress.
    public func connected() {
        lock.withLock {
            _radioOn = true
            abandonIncoming()
        }
    }

    /// The link dropped. A transfer in progress leaves only `incoming.tmp` behind.
    public func connectionDropped() {
        lock.withLock { abandonIncoming() }
    }

    private func abandonIncoming() {
        if let current = incoming {
            leftoverTemp = current.data
            incoming = nil
        }
    }

    // MARK: The protocol

    /// Handle one frame written to RX. Returns the frames to notify on TX, in order.
    public func receive(_ raw: Data) -> [Data] {
        lock.withLock {
            let frames = handle(raw)
            return frames.compactMap { try? $0.encode() }
        }
    }

    private func handle(_ raw: Data) -> [Frame] {
        let frame: Frame
        do {
            frame = try Frame.decode(raw)
        } catch {
            // CHOICE: there is no generic error frame, so a frame that does not parse is dropped.
            _violations.append("undecodable frame: \(error)")
            return []
        }
        _receivedTypes.append(frame.type)
        guard _radioOn else {
            _violations.append("\(frame.type) received after BYE")
            return []
        }

        switch frame {
        case .hello(_, let unixTime):
            // The device answers with its own version; the phone decides whether it can talk to it.
            _helloCount += 1
            _lastHelloTime = unixTime  // the firmware sets its clock from this
            abandonIncoming()
            return [
                .helloAck(
                    HelloAck(
                        version: _protocolVersion, batteryPercent: config.batteryPercent,
                        freeSpaceMB: UInt32(clamping: config.freeBytes / (1024 * 1024)), firmwareVersion: config.firmwareVersion))
            ]

        case .list:
            // As many 9-byte items per notification as fit, then LIST_END with the total.
            // An empty list is just LIST_END 0.
            let perFrame = max(1, (config.maxNotificationLength - 1) / ListItem.encodedSize)
            let items = order.compactMap { stored[$0] }.map { ListItem(id: $0.id, read: $0.read) }
            var frames: [Frame] = []
            var index = 0
            while index < items.count {
                let end = min(items.count, index + perFrame)
                frames.append(.listItems(Array(items[index..<end])))
                index = end
            }
            frames.append(.listEnd(total: UInt16(clamping: items.count)))
            return frames

        case .putBegin(let begin):
            // A new PUT_BEGIN always starts over: incoming.tmp is overwritten.
            incoming = nil
            leftoverTemp = nil
            if !forcedPutReady.isEmpty {
                let status = forcedPutReady.removeFirst()
                if status != .ok { return [.putReady(status)] }
            }
            // CHOICE (as the firmware does): an empty file is a bad request.
            if begin.size == 0 { return [.putReady(.badRequest)] }
            if stored[begin.id] != nil { return [.putReady(.exists)] }
            if Int(begin.size) > config.freeBytes { return [.putReady(.noSpace)] }
            incoming = Incoming(begin: begin)
            return [.putReady(.ok)]

        case .putData(let bytes):
            // PUT_DATA is written without response and never answered directly. Anything wrong
            // with it is remembered and reported by PUT_RESULT after PUT_END.
            guard var current = incoming else {
                _violations.append("PUT_DATA without PUT_BEGIN")
                return []
            }
            if current.failed { return [] }
            let total = current.data.count + bytes.count
            if total > Int(current.begin.size) {
                _violations.append("PUT_DATA beyond the declared size")
                current.failed = true
                incoming = current
                return []
            }
            if total - current.lastReported > config.flowControlWindow {
                _violations.append("flow control: \(total) bytes received, last PUT_PROGRESS was \(current.lastReported)")
            }
            current.data.append(bytes)
            var frames: [Frame] = []
            // PUT_PROGRESS each time another 4096 bytes are on the card, and once at the end
            // (CHOICE, as the firmware does: "the end" is the last byte of the declared size).
            if current.data.count - current.lastReported >= config.progressInterval || current.data.count == Int(current.begin.size) {
                current.lastReported = current.data.count
                frames.append(.putProgress(UInt32(current.data.count)))
            }
            incoming = current
            return frames

        case .putEnd:
            guard var current = incoming else {
                _violations.append("PUT_END without PUT_BEGIN")
                return [.putResult(.badRequest)]
            }
            incoming = nil
            // A failed transfer leaves nothing behind: incoming.tmp is removed.
            if current.failed { return [.putResult(.storageError)] }
            if corruptTransfers > 0, !current.data.isEmpty, current.data.count == Int(current.begin.size) {
                corruptTransfers -= 1
                let index = current.data.startIndex + current.data.count / 2
                current.data[index] ^= 0x5A
            }
            // CHOICE (as the firmware does): a short file is a checksum mismatch too.
            if current.data.count != Int(current.begin.size) || CRC32.checksum(current.data) != current.begin.crc32 {
                return [.putResult(.checksumMismatch)]
            }
            let begin = current.begin
            if stored[begin.id] == nil { order.append(begin.id) }
            stored[begin.id] = Stored(
                id: begin.id, data: current.data, time: begin.time, source: begin.source, title: begin.title,
                author: begin.author, read: false)
            config.freeBytes -= current.data.count
            return [.putResult(.ok)]

        case .delete(let id):
            // CHOICE: deleting an article that is not there succeeds (the outcome is the same).
            if let existing = stored[id] {
                stored[id] = nil
                order.removeAll { $0 == id }
                config.freeBytes += existing.data.count
            }
            return [.deleteResult(.ok)]

        case .bye:
            abandonIncoming()
            _radioOn = false
            return []

        case .helloAck, .listItems, .listEnd, .putReady, .putProgress, .putResult, .deleteResult:
            _violations.append("device-to-phone frame \(frame.type) received from the phone")
            return []
        }
    }
}

/// Connects a `SyncSession` to a `FakeDevice`, with fault injection.
public final class FakeDeviceTransport: SyncTransport, @unchecked Sendable {
    public let device: FakeDevice
    private let inbox = FrameInbox()
    private let lock = NSLock()
    private let attMTU: Int
    private var connected = true
    private var dataBytesSent = 0
    private var dropAfterDataBytes: Int?
    private var muted = false
    private var dropProgress = false
    private var _oversizedWrites = 0
    private var _dataFrames = 0

    /// `attMTU` is the negotiated ATT MTU; a write without response carries at most MTU − 3 bytes.
    public init(device: FakeDevice, attMTU: Int = 185) {
        self.device = device
        self.attMTU = attMTU
    }

    public var oversizedWrites: Int { lock.withLock { _oversizedWrites } }
    public var dataFrames: Int { lock.withLock { _dataFrames } }
    public var isConnected: Bool { lock.withLock { connected } }

    /// Drop the connection once this many PUT_DATA payload bytes have been written (in total).
    public func dropConnection(afterDataBytes count: Int) {
        lock.withLock { dropAfterDataBytes = dataBytesSent + count }
    }

    /// Swallow the device's notifications (the device still acts on writes).
    public func muteDevice(_ muted: Bool) {
        lock.withLock { self.muted = muted }
    }

    /// Lose every PUT_PROGRESS notification from now on (a stalled transfer, as the phone sees it).
    public func dropProgressNotifications(_ drop: Bool) {
        lock.withLock { dropProgress = drop }
    }

    /// Total PUT_DATA payload bytes written so far.
    public var dataBytesWritten: Int { lock.withLock { dataBytesSent } }

    public func disconnect() {
        lock.withLock { connected = false }
        device.connectionDropped()
        inbox.close(.disconnected)
    }

    public func reconnect() {
        lock.withLock {
            connected = true
            dropAfterDataBytes = nil
        }
        inbox.reset()
        device.connected()
    }

    public func maxWriteLength(withResponse: Bool) async -> Int {
        withResponse ? 512 : attMTU - 3
    }

    public func send(_ frame: Data, withResponse: Bool) async throws {
        enum Action {
            case deliver
            case drop
            case refuse
        }
        let limit = withResponse ? 512 : attMTU - 3
        let action: Action = lock.withLock {
            guard connected, device.radioOn else { return .refuse }
            if frame.count > limit { _oversizedWrites += 1 }
            if frame.first == FrameType.putData.rawValue {
                _dataFrames += 1
                dataBytesSent += frame.count - 1
                if let limit = dropAfterDataBytes, dataBytesSent >= limit {
                    dropAfterDataBytes = nil
                    return .drop
                }
            }
            return .deliver
        }
        switch action {
        case .refuse:
            throw SyncError.disconnected
        case .drop:
            disconnect()
            throw SyncError.disconnected
        case .deliver:
            let responses = device.receive(frame)
            let (isMuted, losesProgress) = lock.withLock { (muted, dropProgress) }
            if isMuted { return }
            for response in responses {
                if losesProgress, response.first == FrameType.putProgress.rawValue { continue }
                inbox.push(response)
            }
            if !device.radioOn {
                // BYE: the device switched its radio off, the link is gone.
                lock.withLock { connected = false }
                inbox.close(.disconnected)
            }
        }
    }

    public func receive(timeout: Duration) async throws -> Data {
        try await inbox.next(timeout: timeout)
    }
}
