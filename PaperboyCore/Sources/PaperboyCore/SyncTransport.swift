import Foundation

public enum SyncError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The link went away (or was never up).
    case disconnected
    /// Nothing arrived in time; the string says what was being waited for.
    case timeout(String)
    case versionMismatch(device: UInt8)
    /// The device answered busy (status 1); try again later.
    case deviceBusy
    case protocolViolation(String)
    case transport(String)
    case dataSource(String)
    case cancelled

    public var description: String {
        switch self {
        case .disconnected: return "the device disconnected"
        case .timeout(let what): return "timed out waiting for \(what)"
        case .versionMismatch(let device): return "the device speaks protocol version \(device), this app speaks \(SyncProtocol.version)"
        case .deviceBusy: return "the device is busy"
        case .protocolViolation(let detail): return "protocol violation: \(detail)"
        case .transport(let detail): return "transport error: \(detail)"
        case .dataSource(let detail): return "could not load article data: \(detail)"
        case .cancelled: return "cancelled"
        }
    }
}

/// What a sync session needs from the link. One frame per write and per notification.
///
/// `receive` must hand frames over in the order they arrived, throw `SyncError.timeout` when
/// nothing arrives in time and `SyncError.disconnected` once the link is gone (after any frames
/// that arrived before it went).
public protocol SyncTransport: Sendable {
    /// Largest frame (type byte included) that fits in one write of the given kind.
    func maxWriteLength(withResponse: Bool) async -> Int
    /// Send one frame. With response: returns when the device has acknowledged the write.
    /// Without response: returns when the frame has been handed to the radio (back-pressure).
    func send(_ frame: Data, withResponse: Bool) async throws
    func receive(timeout: Duration) async throws -> Data
}

/// A thread-safe, ordered queue of incoming frames with a timed, cancellable `next`.
/// Transports push from whatever thread their radio calls back on; one consumer awaits.
public final class FrameInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Data] = []
    private var closedWith: SyncError?
    private var waiter: (id: UInt64, continuation: CheckedContinuation<Data, Error>)?
    private var nextWaiterID: UInt64 = 0
    private var finishedWaiterID: UInt64 = 0
    /// Failures (timeout, cancellation) that fired before their waiter had registered.
    private var earlyFailures: [UInt64: SyncError] = [:]

    public init() {}

    /// Deliver a frame. Never blocks.
    public func push(_ frame: Data) {
        let continuation: CheckedContinuation<Data, Error>? = lock.withLock {
            if closedWith != nil { return nil }
            if let current = waiter {
                waiter = nil
                return current.continuation
            }
            queue.append(frame)
            return nil
        }
        continuation?.resume(returning: frame)
    }

    /// Mark the link as gone. Frames already queued are still delivered first.
    public func close(_ error: SyncError = .disconnected) {
        let continuation: CheckedContinuation<Data, Error>? = lock.withLock {
            closedWith = error
            let current = waiter
            waiter = nil
            return current?.continuation
        }
        continuation?.resume(throwing: error)
    }

    /// Forget queued frames and the closed state: a new connection starts clean.
    public func reset() {
        let continuation: CheckedContinuation<Data, Error>? = lock.withLock {
            queue.removeAll()
            closedWith = nil
            let current = waiter
            waiter = nil
            return current?.continuation
        }
        continuation?.resume(throwing: SyncError.disconnected)
    }

    public var isClosed: Bool { lock.withLock { closedWith != nil } }

    private func fail(waiterID: UInt64, with error: SyncError) {
        let continuation: CheckedContinuation<Data, Error>? = lock.withLock {
            guard let current = waiter, current.id == waiterID else {
                if waiterID > finishedWaiterID { earlyFailures[waiterID] = error }
                return nil
            }
            waiter = nil
            return current.continuation
        }
        continuation?.resume(throwing: error)
    }

    /// The next frame, in arrival order.
    public func next(timeout: Duration, waitingFor what: String = "a frame") async throws -> Data {
        let id: UInt64 = lock.withLock {
            nextWaiterID += 1
            return nextWaiterID
        }
        let timer = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            self?.fail(waiterID: id, with: .timeout(what))
        }
        defer {
            timer.cancel()
            lock.withLock {
                earlyFailures[id] = nil
                finishedWaiterID = max(finishedWaiterID, id)
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                enum Step {
                    case frame(Data)
                    case failure(SyncError)
                    case wait
                }
                let step: Step = lock.withLock {
                    if !queue.isEmpty { return .frame(queue.removeFirst()) }
                    if let closedWith { return .failure(closedWith) }
                    if let early = earlyFailures.removeValue(forKey: id) { return .failure(early) }
                    if Task.isCancelled { return .failure(.cancelled) }
                    if waiter != nil { return .failure(.protocolViolation("two consumers on one inbox")) }
                    waiter = (id, continuation)
                    return .wait
                }
                switch step {
                case .frame(let frame): continuation.resume(returning: frame)
                case .failure(let error): continuation.resume(throwing: error)
                case .wait: break
                }
            }
        } onCancel: {
            self.fail(waiterID: id, with: .cancelled)
        }
    }
}
