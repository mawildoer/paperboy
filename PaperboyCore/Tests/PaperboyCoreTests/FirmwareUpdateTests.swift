import Foundation
import Testing
@testable import PaperboyCore

private actor FirmwareTransport: SyncTransport {
    let image: Data
    let stagedStatus: UInt8
    let readyStatus: UInt8
    let badProgress: Bool
    var received = Data()
    var replies: [Data] = []
    var committed = false
    var aborted = false
    var lastProgress = 0

    init(image: Data, stagedStatus: UInt8 = 0, readyStatus: UInt8 = 0, badProgress: Bool = false) {
        self.image = image
        self.stagedStatus = stagedStatus
        self.readyStatus = readyStatus
        self.badProgress = badProgress
    }
    func maxWriteLength(withResponse: Bool) -> Int { 185 }
    func send(_ frame: Data, withResponse: Bool) throws {
        switch frame.first {
        case 0x01:
            replies.append(try Frame.helloAck(HelloAck(version: 1, batteryPercent: 90, freeSpaceMB: 500, firmwareVersion: "bootstrap")).encode())
        case 0x40: replies.append(Data([0xC0, readyStatus]))
        case 0x41:
            received.append(frame.dropFirst())
            // A receiver must see no more than the negotiated window beyond its last ACK.
            #expect(received.count - lastProgress <= SyncProtocol.flowControlWindow)
            if received.count - lastProgress >= SyncProtocol.progressInterval || received.count == image.count {
                var progress = Data([0xC1])
                progress.appendLE(badProgress ? UInt32.max : UInt32(received.count))
                replies.append(progress)
                lastProgress = received.count
            }
        case 0x42: replies.append(Data([0xC2, stagedStatus]))
        case 0x43: committed = true; replies.append(Data([0xC3, 0]))
        case 0x44: aborted = true
        default: Issue.record("Unexpected frame")
        }
    }
    func receive(timeout: Duration) throws -> Data {
        guard !replies.isEmpty else { throw SyncError.timeout("test firmware reply") }
        return replies.removeFirst()
    }
}

@Suite struct FirmwareUpdateTests {
    static let image = Data([0xE9] + Array(repeating: UInt8(42), count: 25_000))

    @Test func completeTransferCommitsOnlyAfterValidatedStaging() async throws {
        let link = FirmwareTransport(image: Self.image)
        let old = try await FirmwareUpdateSession(transport: link).install(Self.image)
        #expect(old == "bootstrap")
        #expect(await link.received == Self.image)
        #expect(await link.committed)
        #expect(await !link.aborted)
    }

    @Test func liveVersionAvoidsReinstallingTheSameRelease() async throws {
        let link = FirmwareTransport(image: Self.image)
        let previous = try await FirmwareUpdateSession(transport: link).install(Self.image, targetVersion: "bootstrap")
        #expect(previous == nil)
        #expect(await link.received.isEmpty)
        #expect(await !link.committed)
    }

    @Test func invalidImageIsRejectedBeforeUsingRadio() async {
        let link = FirmwareTransport(image: Data())
        await #expect(throws: SyncError.self) { try await FirmwareUpdateSession(transport: link).install(Data(repeating: 0, count: 300)) }
        #expect(await link.received.isEmpty)
        #expect(await !link.committed)
    }

    @Test func lowBatteryPreventsTransfer() async {
        let link = FirmwareTransport(image: Self.image, readyStatus: 7)
        await #expect(throws: SyncError.self) { try await FirmwareUpdateSession(transport: link).install(Self.image) }
        #expect(await link.received.isEmpty)
        #expect(await !link.committed)
    }

    @Test func failedIntegrityCheckNeverCommits() async {
        let link = FirmwareTransport(image: Self.image, stagedStatus: 4)
        await #expect(throws: SyncError.self) { try await FirmwareUpdateSession(transport: link).install(Self.image) }
        #expect(await !link.committed)
        #expect(await link.aborted)
    }

    @Test func impossibleAcknowledgementAborts() async {
        let link = FirmwareTransport(image: Self.image, badProgress: true)
        await #expect(throws: SyncError.self) { try await FirmwareUpdateSession(transport: link).install(Self.image) }
        #expect(await !link.committed)
        #expect(await link.aborted)
    }
}
