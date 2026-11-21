import Foundation
import PaperboyBLE
import PaperboyCore

/// The app's Bluetooth link to the reader.
///
/// The CoreBluetooth work is in `BLECentral` (package PaperboyBLE, shared with the Mac CLI so
/// that it is compiled and exercised there): a `CBCentralManager` with a restore identifier,
/// scanning for the service UUID, connect → discover → subscribe, the `SyncTransport`
/// implementation (writes without response wait for `canSendWriteWithoutResponse` /
/// `peripheralIsReady(toSendWriteWithoutResponse:)`), `willRestoreState`, and a connection
/// request that is re-issued after every disconnect.
///
/// This class adds what is specific to the app: remembering which reader is ours, and
/// turning Bluetooth events into UI state and into "the reader is here, sync now".
@MainActor
final class BluetoothTransport: ObservableObject {
    enum LinkState: Equatable {
        case starting
        case unavailable(String)
        case searching
        case waiting  // a connection request is pending; iOS connects when the reader advertises
        case connected(String)
    }

    /// Must stay the same across launches: iOS uses it to hand the central back after
    /// relaunching the app for a Bluetooth event.
    static let restoreIdentifier = "local.paperboy.central"
    private static let knownReaderKey = "paperboy.knownReader"

    @Published private(set) var state: LinkState = .starting
    @Published private(set) var knownReader: UUID?

    let central: BLECentral
    /// Called each time the reader is connected and ready for a session.
    var onReady: (() -> Void)?
    private var listener: Task<Void, Never>?

    init() {
        knownReader = UserDefaults.standard.string(forKey: Self.knownReaderKey).flatMap(UUID.init(uuidString:))
        central = BLECentral(
            options: .init(
                restoreIdentifier: Self.restoreIdentifier,
                autoReconnect: true,
                log: { AppLog.post($0) }))
    }

    /// The transport a `SyncSession` talks through.
    var transport: any SyncTransport { central }

    /// Begin listening and ask for a connection. Safe to call more than once.
    func start() {
        if listener == nil {
            let events = central.events
            listener = Task { [weak self] in
                for await event in events {
                    self?.handle(event)
                }
            }
        }
        requestConnection()
    }

    private func requestConnection() {
        if let knownReader {
            // Stays pending indefinitely. UNVERIFIED: that iOS wakes the suspended (or
            // terminated, via state restoration) app when the bonded reader advertises.
            central.connect(to: knownReader)
            if case .connected = state {} else { state = .waiting }
        } else {
            // First run: take the first reader that advertises the Paperboy service.
            central.connectToFirstReader()
            state = .searching
        }
    }

    /// Forget the paired reader and look for one again.
    func forgetReader() {
        UserDefaults.standard.removeObject(forKey: Self.knownReaderKey)
        knownReader = nil
        central.disconnect(forget: true)
        requestConnection()
    }

    private func handle(_ event: BLEEvent) {
        switch event {
        case .state(let name, let poweredOn):
            if poweredOn {
                if case .unavailable = state { state = knownReader == nil ? .searching : .waiting }
            } else if name == "unauthorized" {
                state = .unavailable("Bluetooth permission is off for Paperboy")
            } else if name == "poweredOff" {
                state = .unavailable("Bluetooth is off")
            } else if name == "unsupported" {
                state = .unavailable("This device has no Bluetooth LE")
            }
        case .discovered:
            break
        case .connecting:
            if case .connected = state {} else { state = .waiting }
        case .ready(let identifier, let name):
            if knownReader != identifier {
                knownReader = identifier
                UserDefaults.standard.set(identifier.uuidString, forKey: Self.knownReaderKey)
            }
            state = .connected(name ?? "Reader")
            onReady?()
        case .disconnected:
            // BLECentral has already re-issued the connection request (autoReconnect).
            state = knownReader == nil ? .searching : .waiting
        case .restored(let identifiers):
            AppLog.shared.add("Bluetooth state restored with \(identifiers.count) peripheral(s)")
        }
    }
}
