import CryptoKit
import Foundation
import Testing
@testable import PaperboyCore

private actor CommitIntent {
    var saved = false
    func remember() { saved = true }
}

private actor ResumeTransport: SyncTransport {
    var image: Data
    var retained: Data
    var identity: Data
    var replies: [Data] = []
    var committed = false
    var aborted = false
    var transmitted = 0
    var progressAt = 0
    var cancelWhenStaged = false
    var receiving = false
    var validated = false
    let commitStatus: UInt8
    let invalidOffset: Bool
    let intent: CommitIntent?

    init(image: Data, saved: Data = Data(), identity: Data? = nil, invalidOffset: Bool = false, intent: CommitIntent? = nil, commitStatus: UInt8 = 0) {
        self.image = image
        self.retained = saved
        self.identity = identity ?? Data(SHA256.hash(data: image))
        self.invalidOffset = invalidOffset
        self.intent = intent
        self.commitStatus = commitStatus
    }
    var canSyncArticles: Bool { !receiving && !validated && !committed }
    func setCancelWhenStaged(_ value: Bool) { cancelWhenStaged = value }
    func maxWriteLength(withResponse: Bool) -> Int { 185 }
    func send(_ frame: Data, withResponse: Bool) async throws {
        switch frame.first {
        case 0x01:
            replies.append(try Frame.helloAck(HelloAck(version: 3, batteryPercent: 90, freeSpaceMB: 500, firmwareVersion: "0.3.1-paperboy")).encode())
        case 0x45:
            receiving = true; validated = false
            #expect(frame.count == 41)
            let next = Data(frame.suffix(32))
            if next != identity { identity = next; retained.removeAll() }
            #expect(next == Data(SHA256.hash(data: image)))
            progressAt = retained.count
            var ready = Data([0xC5, 0])
            ready.appendLE(invalidOffset ? UInt32.max : UInt32(retained.count))
            ready.appendLE(CRC32.checksum(retained))
            replies.append(ready)
        case 0x41:
            retained.append(frame.dropFirst())
            transmitted += frame.count - 1
            #expect(retained.count - progressAt <= SyncProtocol.flowControlWindow)
            if retained.count - progressAt >= SyncProtocol.progressInterval || retained.count == image.count {
                var progress = Data([0xC1]); progress.appendLE(UInt32(retained.count)); replies.append(progress)
                progressAt = retained.count
            }
        case 0x46:
            let allowed = receiving || validated
            if allowed { receiving = false; validated = false }
            var paused = Data([0xC6, allowed ? 0 : 5]); paused.appendLE(UInt32(retained.count)); paused.appendLE(CRC32.checksum(retained))
            replies.append(paused)
        case 0x42:
            #expect(retained == image)
            receiving = false; validated = true
            replies.append(Data([0xC2, 0]))
            if cancelWhenStaged { withUnsafeCurrentTask { $0?.cancel() } }
        case 0x43:
            if let intent { #expect(await intent.saved) }
            #expect(retained == image)
            if commitStatus == 0 { committed = true; validated = false }
            replies.append(Data([0xC3, commitStatus]))
        case 0x44: aborted = true; receiving = false; validated = false; retained.removeAll()
        default: Issue.record("unexpected firmware frame")
        }
    }
    func receive(timeout: Duration) throws -> Data {
        guard !replies.isEmpty else { throw SyncError.timeout("resume test") }
        return replies.removeFirst()
    }
}

@Suite struct FirmwareResumeTests {
    private static let image = Data([0xE9] + Array(repeating: UInt8(42), count: 25_000))

    @Test func severalWindowsAndReaderRestartOnlySendMissingBytes() async throws {
        let first = ResumeTransport(image: Self.image)
        let session = FirmwareUpdateSession(transport: first)
        #expect(try await session.transfer(Self.image, maximumTransferBytes: 5500) == .paused(bytes: 5500))
        #expect(try await session.transfer(Self.image, maximumTransferBytes: 7000) == .paused(bytes: 12500))
        #expect(await !first.committed)
        let saved = await first.retained
        #expect(saved == Self.image.prefix(12500))
        let intent = CommitIntent()
        let restarted = ResumeTransport(image: Self.image, saved: saved, intent: intent)
        #expect(try await FirmwareUpdateSession(transport: restarted).transfer(Self.image, willCommit: { _ in await intent.remember() }) == .committed(previous: "0.3.1-paperboy"))
        #expect(await restarted.transmitted == Self.image.count - saved.count)
        #expect(await restarted.retained == Self.image)
        #expect(await restarted.committed)
    }

    @Test func fullImageInAShortWindowWaitsToFlashWithoutUploadingAgain() async throws {
        let reader = ResumeTransport(image: Self.image)
        let session = FirmwareUpdateSession(transport: reader)
        #expect(try await session.transfer(Self.image, maximumTransferBytes: Self.image.count) == .paused(bytes: Self.image.count))
        #expect(await !reader.committed)
        #expect(try await session.transfer(Self.image) == .committed(previous: "0.3.1-paperboy"))
        #expect(await reader.transmitted == Self.image.count)
    }

    @Test func corruptPrefixIsRejectedAndResetBeforeSendingMoreBytes() async throws {
        let reader = ResumeTransport(image: Self.image, saved: Data(repeating: 0, count: 300))
        await #expect(throws: SyncError.self) { try await FirmwareUpdateSession(transport: reader).transfer(Self.image) }
        #expect(await reader.aborted)
        #expect(await reader.transmitted == 0)
        #expect(await !reader.committed)
        #expect(await reader.retained.isEmpty)
    }

    @Test func anotherReleaseDoesNotReuseAnOldImagesPrefix() async throws {
        let next = Data([0xE9] + Array(repeating: UInt8(43), count: 25_000))
        let reader = ResumeTransport(image: next, saved: Self.image.prefix(1000), identity: Data(SHA256.hash(data: Self.image)))
        #expect(try await FirmwareUpdateSession(transport: reader).transfer(next, maximumTransferBytes: 600) == .paused(bytes: 600))
        #expect(await reader.retained == next.prefix(600))
        #expect(await reader.transmitted == 600)
    }

    @Test func cancellationAfterFullStagingKeepsBytesAndNeverCommits() async throws {
        let reader = ResumeTransport(image: Self.image)
        await reader.setCancelWhenStaged(true)
        let task = Task { try await FirmwareUpdateSession(transport: reader).transfer(Self.image) }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await !reader.committed)
        #expect(await !reader.aborted)
        #expect(await reader.retained == Self.image)
        await reader.setCancelWhenStaged(false)
        #expect(try await FirmwareUpdateSession(transport: reader).transfer(Self.image) == .committed(previous: "0.3.1-paperboy"))
        #expect(await reader.transmitted == Self.image.count)
    }

    @Test func invalidResumeOffsetCannotCauseAnOutOfBoundsUpload() async {
        let reader = ResumeTransport(image: Self.image, invalidOffset: true)
        await #expect(throws: SyncError.self) { try await FirmwareUpdateSession(transport: reader).transfer(Self.image) }
        #expect(await reader.transmitted == 0)
        #expect(await !reader.committed)
    }

    @Test func failedConfirmationPersistenceNeverCommitsAndKeepsTheFullStage() async {
        let reader = ResumeTransport(image: Self.image)
        await #expect(throws: SyncError.self) {
            try await FirmwareUpdateSession(transport: reader).transfer(Self.image, willCommit: { _ in
                throw SyncError.dataSource("confirmation record could not be written")
            })
        }
        #expect(await !reader.committed)
        #expect(await !reader.aborted)
        #expect(await reader.retained == Self.image)
        #expect(await reader.canSyncArticles)
    }

    @Test func explicitCommitDeclineIsDistinguishedFromAnUncertainDelivery() async {
        let reader = ResumeTransport(image: Self.image, commitStatus: 7)
        do {
            _ = try await FirmwareUpdateSession(transport: reader).transfer(Self.image)
            Issue.record("commit should have been declined")
        } catch let error as FirmwareCommitRejection {
            #expect(error.status == 7)
        } catch { Issue.record("expected a definitive commit rejection, got \(error)") }
        #expect(await !reader.committed)
        #expect(await reader.canSyncArticles)
        #expect(await reader.retained == Self.image)
    }
}
