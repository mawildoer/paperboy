@preconcurrency import CoreBluetooth
import Foundation
import PaperboyCore

public enum BLEEvent: Sendable {
    /// Bluetooth state changed ("poweredOn", "unauthorized", …).
    case state(String, poweredOn: Bool)
    case discovered(identifier: UUID, name: String?, rssi: Int)
    case connecting(identifier: UUID)
    /// Connected, characteristics found, notifications on: a sync session can start.
    case ready(identifier: UUID, name: String?)
    case disconnected(identifier: UUID, reason: String?)
    /// iOS relaunched the app and handed back these peripherals.
    case restored(identifiers: [UUID])
}

/// CoreBluetooth central for the Paperboy service. It is the `SyncTransport` used by both the
/// iOS app and the Mac CLI.
///
/// All CoreBluetooth objects and all mutable state live on one private serial queue, which is
/// also the queue CoreBluetooth calls the delegate on.
public final class BLECentral: NSObject, SyncTransport, @unchecked Sendable {
    public struct Options: Sendable {
        /// State-restoration identifier. iOS only does anything with it; nil turns it off.
        public var restoreIdentifier: String?
        /// After a disconnect, immediately ask for the connection again. The request never times
        /// out, so the system connects as soon as the reader advertises (and on iOS wakes the app).
        public var autoReconnect = false
        public var log: (@Sendable (String) -> Void)?

        public init(restoreIdentifier: String? = nil, autoReconnect: Bool = false, log: (@Sendable (String) -> Void)? = nil) {
            self.restoreIdentifier = restoreIdentifier
            self.autoReconnect = autoReconnect
            self.log = log
        }
    }

    public static let serviceUUID = CBUUID(string: SyncProtocol.serviceUUID)
    public static let rxUUID = CBUUID(string: SyncProtocol.rxCharacteristicUUID)
    public static let txUUID = CBUUID(string: SyncProtocol.txCharacteristicUUID)

    /// Everything that happens, in order. One consumer.
    public let events: AsyncStream<BLEEvent>

    private let eventContinuation: AsyncStream<BLEEvent>.Continuation
    private let queue = DispatchQueue(label: "paperboy.ble")
    private let options: Options
    private let inbox = FrameInbox()

    // Queue-confined state.
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private var tx: CBCharacteristic?
    private var isReady = false
    private var wantsScan = false
    private var connectToFirstDiscovered = false
    private var targetIdentifier: UUID?
    private var pendingWrite: CheckedContinuation<Void, Error>?
    private var pendingWriteFrame: Data?
    private var pairingRetriesLeft = 0
    /// 1.5 s apart: about a minute for the person to accept the pairing prompt.
    private static let pairingRetries = 40
    private var pendingUnacknowledged: (frame: Data, continuation: CheckedContinuation<Void, Error>)?
    private var readyWaiters: [(id: Int, continuation: CheckedContinuation<Void, Error>)] = []
    private var powerWaiters: [(id: Int, continuation: CheckedContinuation<Void, Error>)] = []
    private var nextWaiterID = 0

    public init(options: Options = Options()) {
        self.options = options
        var continuation: AsyncStream<BLEEvent>.Continuation?
        events = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation = $0 }
        // The stream's build closure runs synchronously, so this is always set.
        eventContinuation = continuation ?? AsyncStream<BLEEvent>.makeStream().continuation
        super.init()
        var managerOptions: [String: Any] = [:]
        if let identifier = options.restoreIdentifier {
            managerOptions[CBCentralManagerOptionRestoreIdentifierKey] = identifier
        }
        let manager = CBCentralManager(delegate: self, queue: queue, options: managerOptions)
        queue.async { self.central = manager }
    }

    private func log(_ message: String) {
        options.log?("[ble] \(message)")
    }

    private func emit(_ event: BLEEvent) {
        eventContinuation.yield(event)
    }

    // MARK: Control

    /// Wait for Bluetooth to be powered on. Throws if it is off, unsupported or not permitted.
    public func waitUntilPoweredOn(timeout: Duration = .seconds(10)) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                if let state = self.central?.state {
                    if state == .poweredOn {
                        continuation.resume()
                        return
                    }
                    if let failure = Self.failure(for: state) {
                        continuation.resume(throwing: failure)
                        return
                    }
                }
                let id = self.makeWaiterID()
                self.powerWaiters.append((id, continuation))
                self.queue.asyncAfter(deadline: .now() + timeout.timeInterval) {
                    if let index = self.powerWaiters.firstIndex(where: { $0.id == id }) {
                        self.powerWaiters.remove(at: index).continuation.resume(throwing: SyncError.timeout("Bluetooth to power on"))
                    }
                }
            }
        }
    }

    /// Scan for readers advertising the Paperboy service; results arrive as `.discovered` events.
    public func startScan() {
        queue.async {
            self.wantsScan = true
            self.scanIfPossible()
        }
    }

    public func stopScan() {
        queue.async {
            self.wantsScan = false
            self.connectToFirstDiscovered = false
            if let central = self.central, central.state == .poweredOn { central.stopScan() }
        }
    }

    /// Ask for a connection to a known reader. The request stays pending until the reader
    /// shows up, however long that takes. If the system no longer knows the identifier, a scan
    /// is started and the reader is connected when it is seen.
    public func connect(to identifier: UUID) {
        queue.async {
            self.targetIdentifier = identifier
            self.connectTargetIfPossible()
        }
    }

    /// Scan and connect to the first reader found.
    public func connectToFirstReader() {
        queue.async {
            self.connectToFirstDiscovered = true
            self.wantsScan = true
            self.scanIfPossible()
        }
    }

    /// Wait until a reader is connected and ready for a session.
    public func waitUntilReady(timeout: Duration) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                if self.isReady {
                    continuation.resume()
                    return
                }
                let id = self.makeWaiterID()
                self.readyWaiters.append((id, continuation))
                self.queue.asyncAfter(deadline: .now() + timeout.timeInterval) {
                    if let index = self.readyWaiters.firstIndex(where: { $0.id == id }) {
                        self.readyWaiters.remove(at: index).continuation.resume(throwing: SyncError.timeout("the reader to connect"))
                    }
                }
            }
        }
    }

    /// Drop the connection (and any pending connection request). With `forget`, auto-reconnect
    /// stops until `connect` is called again.
    public func disconnect(forget: Bool = false) {
        queue.async {
            if forget { self.targetIdentifier = nil }
            if let peripheral = self.peripheral, let central = self.central, central.state == .poweredOn {
                central.cancelPeripheralConnection(peripheral)
            }
        }
    }

    public var connectedIdentifier: UUID? {
        get async {
            await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: self.isReady ? self.peripheral?.identifier : nil) }
            }
        }
    }

    // MARK: SyncTransport

    public func maxWriteLength(withResponse: Bool) async -> Int {
        await withCheckedContinuation { continuation in
            queue.async {
                guard let peripheral = self.peripheral, self.isReady else {
                    continuation.resume(returning: 20)
                    return
                }
                let usesResponse = withResponse || !self.supportsWriteWithoutResponse
                continuation.resume(returning: peripheral.maximumWriteValueLength(for: usesResponse ? .withResponse : .withoutResponse))
            }
        }
    }

    public func send(_ frame: Data, withResponse: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard self.isReady, let peripheral = self.peripheral, let rx = self.rx else {
                    continuation.resume(throwing: SyncError.disconnected)
                    return
                }
                guard self.pendingWrite == nil, self.pendingUnacknowledged == nil else {
                    continuation.resume(throwing: SyncError.transport("a write is already in progress"))
                    return
                }
                if withResponse || !self.supportsWriteWithoutResponse {
                    self.pendingWrite = continuation
                    self.pendingWriteFrame = frame
                    self.pairingRetriesLeft = Self.pairingRetries
                    peripheral.writeValue(frame, for: rx, type: .withResponse)
                } else if peripheral.canSendWriteWithoutResponse {
                    peripheral.writeValue(frame, for: rx, type: .withoutResponse)
                    continuation.resume()
                } else {
                    // Back-pressure: wait for peripheralIsReady(toSendWriteWithoutResponse:).
                    self.pendingUnacknowledged = (frame, continuation)
                }
            }
        }
    }

    public func receive(timeout: Duration) async throws -> Data {
        try await inbox.next(timeout: timeout)
    }

    // MARK: Queue-confined helpers

    private var supportsWriteWithoutResponse: Bool {
        rx?.properties.contains(.writeWithoutResponse) ?? false
    }

    private func makeWaiterID() -> Int {
        nextWaiterID += 1
        return nextWaiterID
    }

    private static func failure(for state: CBManagerState) -> SyncError? {
        switch state {
        case .unsupported: return .transport("this machine has no Bluetooth LE")
        case .unauthorized: return .transport("Bluetooth permission was denied (System Settings › Privacy & Security › Bluetooth)")
        case .poweredOff: return .transport("Bluetooth is switched off")
        default: return nil  // unknown, resetting: keep waiting
        }
    }

    private static func name(of state: CBManagerState) -> String {
        switch state {
        case .unknown: return "unknown"
        case .resetting: return "resetting"
        case .unsupported: return "unsupported"
        case .unauthorized: return "unauthorized"
        case .poweredOff: return "poweredOff"
        case .poweredOn: return "poweredOn"
        @unknown default: return "state \(state.rawValue)"
        }
    }

    private func scanIfPossible() {
        guard wantsScan, let central, central.state == .poweredOn else { return }
        log("scanning for service \(Self.serviceUUID.uuidString)")
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func connectTargetIfPossible() {
        guard let central, central.state == .poweredOn, let target = targetIdentifier else { return }
        if let current = peripheral, current.identifier == target {
            if current.state == .connected {
                if !isReady { beginDiscovery(current) }
                return
            }
            if current.state == .connecting { return }
        }
        if let known = central.retrievePeripherals(withIdentifiers: [target]).first {
            startConnecting(known)
        } else if let connected = central.retrieveConnectedPeripherals(withServices: [Self.serviceUUID]).first(where: { $0.identifier == target }) {
            startConnecting(connected)
        } else {
            log("the system does not know \(target); scanning for it")
            wantsScan = true
            scanIfPossible()
        }
    }

    private func startConnecting(_ target: CBPeripheral) {
        guard let central else { return }
        peripheral = target  // CoreBluetooth does not retain peripherals; we must
        target.delegate = self
        log("requesting connection to \(target.identifier) (\(target.name ?? "unnamed"))")
        emit(.connecting(identifier: target.identifier))
        central.connect(target, options: nil)
    }

    private func beginDiscovery(_ target: CBPeripheral) {
        target.delegate = self
        target.discoverServices([Self.serviceUUID])
    }

    private func tearDown(reason: SyncError) {
        isReady = false
        rx = nil
        tx = nil
        if let write = pendingWrite {
            pendingWrite = nil
            write.resume(throwing: reason)
        }
        if let pending = pendingUnacknowledged {
            pendingUnacknowledged = nil
            pending.continuation.resume(throwing: reason)
        }
        inbox.close(reason)
    }

    private func failSetup(_ target: CBPeripheral, _ message: String) {
        log(message)
        central?.cancelPeripheralConnection(target)
    }
}

// MARK: - CBCentralManagerDelegate

extension BLECentral: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        self.central = central
        let state = central.state
        log("Bluetooth state: \(Self.name(of: state))")
        emit(.state(Self.name(of: state), poweredOn: state == .poweredOn))
        if state == .poweredOn {
            let waiters = powerWaiters
            powerWaiters = []
            for waiter in waiters { waiter.continuation.resume() }
            connectTargetIfPossible()
            scanIfPossible()
        } else {
            if let failure = Self.failure(for: state) {
                let waiters = powerWaiters
                powerWaiters = []
                for waiter in waiters { waiter.continuation.resume(throwing: failure) }
            }
            if isReady || pendingWrite != nil || pendingUnacknowledged != nil { tearDown(reason: .disconnected) }
        }
    }

    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // Called before centralManagerDidUpdateState when iOS relaunches the app for a Bluetooth
        // event. The peripherals come back connected or with a connection pending.
        self.central = central
        let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? []
        log("restoring \(restored.count) peripheral(s)")
        if let first = restored.first {
            peripheral = first
            first.delegate = self
            if targetIdentifier == nil { targetIdentifier = first.identifier }
        }
        emit(.restored(identifiers: restored.map(\.identifier)))
        // Nothing else may be done until the state is poweredOn; connectTargetIfPossible() then
        // starts discovery on an already-connected peripheral or re-issues the connection request.
    }

    public func centralManager(
        _ central: CBCentralManager, didDiscover discovered: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? discovered.name
        log("discovered \(discovered.identifier) name=\(name ?? "-") rssi=\(RSSI.intValue)")
        emit(.discovered(identifier: discovered.identifier, name: name, rssi: RSSI.intValue))
        let isTarget = targetIdentifier == discovered.identifier
        if connectToFirstDiscovered || isTarget {
            if let current = peripheral, current.state == .connecting || current.state == .connected { return }
            connectToFirstDiscovered = false
            wantsScan = false
            central.stopScan()
            targetIdentifier = discovered.identifier
            startConnecting(discovered)
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect connected: CBPeripheral) {
        log("connected to \(connected.identifier); discovering the service")
        peripheral = connected
        beginDiscovery(connected)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect failed: CBPeripheral, error: Error?) {
        log("failed to connect to \(failed.identifier): \(error?.localizedDescription ?? "no reason given")")
        emit(.disconnected(identifier: failed.identifier, reason: error?.localizedDescription ?? "failed to connect"))
        let waiters = readyWaiters
        readyWaiters = []
        for waiter in waiters {
            waiter.continuation.resume(throwing: SyncError.transport("failed to connect: \(error?.localizedDescription ?? "unknown")"))
        }
        if options.autoReconnect, targetIdentifier == failed.identifier { startConnecting(failed) }
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral gone: CBPeripheral, error: Error?) {
        log("disconnected from \(gone.identifier)\(error.map { ": \($0.localizedDescription)" } ?? "")")
        tearDown(reason: .disconnected)
        emit(.disconnected(identifier: gone.identifier, reason: error?.localizedDescription))
        if options.autoReconnect, targetIdentifier == gone.identifier {
            // Keep a connection request pending: this is what lets iOS wake the app when the
            // reader next advertises.
            startConnecting(gone)
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLECentral: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            failSetup(peripheral, "service discovery failed: \(error.localizedDescription)")
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            failSetup(peripheral, "the Paperboy service is missing on \(peripheral.identifier)")
            return
        }
        peripheral.discoverCharacteristics([Self.rxUUID, Self.txUUID], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            failSetup(peripheral, "characteristic discovery failed: \(error.localizedDescription)")
            return
        }
        let characteristics = service.characteristics ?? []
        guard let rx = characteristics.first(where: { $0.uuid == Self.rxUUID }),
              let tx = characteristics.first(where: { $0.uuid == Self.txUUID })
        else {
            failSetup(peripheral, "RX/TX characteristics are missing")
            return
        }
        self.rx = rx
        self.tx = tx
        log("RX properties=\(rx.properties.rawValue) TX properties=\(tx.properties.rawValue); subscribing to TX")
        // UNVERIFIED: both characteristics require encryption. Subscribing is expected to make
        // the system pair (Just Works, no prompt on iOS beyond the pairing alert) and then retry.
        peripheral.setNotifyValue(true, for: tx)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.txUUID else { return }
        if let error {
            failSetup(peripheral, "could not subscribe to TX (pairing refused?): \(error.localizedDescription)")
            return
        }
        guard characteristic.isNotifying else { return }
        inbox.reset()  // a new connection starts with no stale frames
        isReady = true
        log(
            "ready; max write: \(peripheral.maximumWriteValueLength(for: .withoutResponse)) without response, "
                + "\(peripheral.maximumWriteValueLength(for: .withResponse)) with response")
        emit(.ready(identifier: peripheral.identifier, name: peripheral.name))
        let waiters = readyWaiters
        readyWaiters = []
        for waiter in waiters { waiter.continuation.resume() }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.txUUID, error == nil, let value = characteristic.value, !value.isEmpty else { return }
        inbox.push(value)
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let write = pendingWrite else { return }
        // The first write to a reader this phone has not paired with is refused while iOS shows the
        // pairing prompt (seen 16/11/2026: "Authentication is insufficient"). Repeat it until the
        // person has answered, instead of failing the session.
        if let attError = error as? CBATTError,
           attError.code == .insufficientAuthentication || attError.code == .insufficientEncryption,
           pairingRetriesLeft > 0, let frame = pendingWriteFrame {
            pairingRetriesLeft -= 1
            if pairingRetriesLeft == Self.pairingRetries - 1 { log("waiting for pairing to be accepted") }
            queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.pendingWrite != nil, self.isReady,
                      let peripheral = self.peripheral, let rx = self.rx else { return }
                peripheral.writeValue(frame, for: rx, type: .withResponse)
            }
            return
        }
        pendingWrite = nil
        pendingWriteFrame = nil
        if let error {
            write.resume(throwing: SyncError.transport("write failed: \(error.localizedDescription)"))
        } else {
            write.resume()
        }
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard let pending = pendingUnacknowledged, let rx else { return }
        pendingUnacknowledged = nil
        peripheral.writeValue(pending.frame, for: rx, type: .withoutResponse)
        pending.continuation.resume()
    }

    public func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        // The reader's GATT table changed (new firmware): look again.
        guard invalidatedServices.contains(where: { $0.uuid == Self.serviceUUID }) else { return }
        log("services changed; rediscovering")
        tearDown(reason: .disconnected)
        beginDiscovery(peripheral)
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
