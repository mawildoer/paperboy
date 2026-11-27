import CryptoKit
import Foundation
import Testing
@testable import PaperboyCore

private final class FirmwareURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [String: Data] = [:]
    nonisolated(unsafe) private static var requested: [String] = []
    static func configure(_ values: [String: Data]) {
        lock.withLock { responses = values; requested = [] }
    }
    static var requestCount: Int { lock.withLock { requested.count } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let data = Self.lock.withLock {
            Self.requested.append(url.absoluteString)
            return Self.responses[url.absoluteString]
        }
        guard let data else { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct FirmwareRepositoryTests {
    private let api = "https://api.github.com/repos/mawildoer/crosspoint-reader/releases/latest"
    private let imageURL = "https://github.com/mawildoer/crosspoint-reader/releases/download/paperboy-v0.3.1/paperboy-x3-update.bin"
    private let sumsURL = "https://github.com/mawildoer/crosspoint-reader/releases/download/paperboy-v0.3.1/SHA256SUMS"
    private let image = Data([0xE9] + Array(repeating: UInt8(42), count: 1023))

    private func responses() -> [String: Data] {
        let digest = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
        let json = #"{"tag_name":"paperboy-v0.3.1","assets":[{"name":"paperboy-x3-update.bin","browser_download_url":"\#(imageURL)"},{"name":"SHA256SUMS","browser_download_url":"\#(sumsURL)"}]}"#
        return [api: Data(json.utf8), sumsURL: Data("\(digest)  paperboy-x3-update.bin\n".utf8), imageURL: image]
    }
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FirmwareURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test func nextBackgroundRunUsesVerifiedDiskCacheWithoutNetwork() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        FirmwareURLProtocol.configure(responses())
        let repository = FirmwareRepository(directory: dir, session: session())
        let date = Date(timeIntervalSince1970: 100_000)
        let release = try await repository.latestMetadata(now: date)
        #expect(try await repository.image(for: release) == image)
        #expect(FirmwareURLProtocol.requestCount == 3)
        FirmwareURLProtocol.configure([:])
        let relaunched = FirmwareRepository(directory: dir, session: session())
        #expect(try await relaunched.latestMetadata(now: date.addingTimeInterval(60)) == release)
        #expect(try await relaunched.image(for: release) == image)
        #expect(FirmwareURLProtocol.requestCount == 0)
        await #expect(throws: URLError.self) { try await relaunched.latestMetadata(now: date, force: true) }
    }

    @Test func offlineRefreshOffersOnlyAnAlreadyVerifiedUpgrade() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = FirmwareRepository(directory: dir, session: session())
        FirmwareURLProtocol.configure(responses())
        let release = try await repository.latestMetadata()
        // Lose internet before the binary arrives. Metadata alone cannot authorize an offline update.
        FirmwareURLProtocol.configure([:])
        await #expect(throws: URLError.self) { try await repository.image(for: release) }
        await #expect(throws: URLError.self) { try await repository.latestMetadata(force: true, installedVersion: "0.3.0-paperboy") }
        FirmwareURLProtocol.configure([imageURL: image])
        #expect(try await repository.image(for: release) == image)

        FirmwareURLProtocol.configure([:])
        let relaunched = FirmwareRepository(directory: dir, session: session())
        let expired = Date().addingTimeInterval(FirmwareUpdatePolicy.checkInterval + 1)
        #expect(try await relaunched.latestMetadata(now: expired, installedVersion: "0.3.0-paperboy") == release)
        #expect(try await relaunched.image(for: release) == image)
        #expect(FirmwareURLProtocol.requestCount == 1)
        await #expect(throws: URLError.self) { try await relaunched.latestMetadata(now: expired, installedVersion: release.version) }
        let path = dir.appendingPathComponent("firmware-\(release.digest).bin")
        try Data(repeating: 0, count: image.count).write(to: path)
        await #expect(throws: URLError.self) { try await relaunched.latestMetadata(now: expired, installedVersion: "0.3.0-paperboy") }
    }

    @Test func damagedCachedImageIsDownloadedAndCheckedAgain() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        FirmwareURLProtocol.configure(responses())
        let repository = FirmwareRepository(directory: dir, session: session())
        let release = try await repository.latestMetadata()
        _ = try await repository.image(for: release)
        let path = dir.appendingPathComponent("firmware-\(release.digest).bin")
        try Data([0xE9] + Array(repeating: UInt8(0), count: 1023)).write(to: path)
        FirmwareURLProtocol.configure([imageURL: image])
        #expect(try await repository.image(for: release) == image)
        #expect(FirmwareURLProtocol.requestCount == 1)
        #expect(try Data(contentsOf: path) == image)
    }

    @Test func wrongDownloadedChecksumIsNeverCached() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        var values = responses()
        values[imageURL] = Data([0xE9] + Array(repeating: UInt8(0), count: 1023))
        FirmwareURLProtocol.configure(values)
        let repository = FirmwareRepository(directory: dir, session: session())
        let release = try await repository.latestMetadata()
        await #expect(throws: SyncError.self) { try await repository.image(for: release) }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("firmware-\(release.digest).bin").path))
    }

    @Test func expiredMetadataIsRefreshed() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        FirmwareURLProtocol.configure(responses())
        let repository = FirmwareRepository(directory: dir, session: session())
        let date = Date(timeIntervalSince1970: 100_000)
        _ = try await repository.latestMetadata(now: date)
        FirmwareURLProtocol.configure(responses())
        _ = try await repository.latestMetadata(now: date.addingTimeInterval(FirmwareUpdatePolicy.checkInterval))
        #expect(FirmwareURLProtocol.requestCount == 2)
    }

    @Test func interruptedFirmwareDownloadsAreDeferredWithoutExposingURLSessionDiagnostics() throws {
        let cancelled = NSError(domain: NSURLErrorDomain, code: -999, userInfo: [
            NSURLErrorFailingURLStringErrorKey: imageURL, NSLocalizedDescriptionKey: "cancelled"
        ])
        for error: Error in [cancelled, CancellationError(), SyncError.cancelled] {
            let interruption = try #require(FirmwareInterruption(error))
            #expect(interruption == .cancelled)
            #expect(interruption.message(automatic: true) == nil)
            #expect(interruption.message(automatic: false)?.contains("Tap Update") == true)
        }
        for code: URLError.Code in [.notConnectedToInternet, .networkConnectionLost, .timedOut, .dnsLookupFailed] {
            let interruption = try #require(FirmwareInterruption(URLError(code)))
            #expect(interruption == .connection)
            #expect(interruption.message(automatic: true)?.contains("later sync") == true)
        }
        #expect(FirmwareInterruption(URLError(.serverCertificateUntrusted)) == nil)
        #expect(FirmwareInterruption(SyncError.dataSource("checksum mismatch")) == nil)
        #expect(FirmwareInterruption(NSError(domain: NSPOSIXErrorDomain, code: -999)) == nil)
    }

    @Test func automaticPolicyDoesNotDowngradeOrReplaceUnknownDevelopmentBuilds() {
        #expect(FirmwareUpdatePolicy.isUpgrade("0.3.10-paperboy", from: "0.3.9-paperboy"))
        #expect(!FirmwareUpdatePolicy.isUpgrade("0.3.1-paperboy", from: "0.3.1-paperboy"))
        #expect(!FirmwareUpdatePolicy.isUpgrade("0.3.0-paperboy", from: "0.3.1-paperboy"))
        #expect(!FirmwareUpdatePolicy.isUpgrade("0.3.1-paperboy", from: "2.0.0-dev-feat/paperboy-123"))
        #expect(!FirmwareUpdatePolicy.isUpgrade("0.3.1-paperboy", from: "bootstrap"))
        #expect(!FirmwareUpdatePolicy.isUpgrade("0.3.-1-paperboy", from: "0.2.0-paperboy"))
        let date = Date(timeIntervalSince1970: 100_000)
        #expect(FirmwareUpdatePolicy.attemptDue(lastAttempt: nil, now: date))
        #expect(!FirmwareUpdatePolicy.attemptDue(lastAttempt: date, now: date.addingTimeInterval(59 * 60)))
        #expect(FirmwareUpdatePolicy.attemptDue(lastAttempt: date, now: date.addingTimeInterval(60 * 60)))
        #expect(FirmwareUpdatePolicy.attemptDue(lastAttempt: date, now: date.addingTimeInterval(-60)))
        #expect(!FirmwareUpdatePolicy.attemptDue(lastAttempt: date, now: date.addingTimeInterval(59), afterInterruption: true))
        #expect(FirmwareUpdatePolicy.attemptDue(lastAttempt: date, now: date.addingTimeInterval(60), afterInterruption: true))
        #expect(!FirmwareUpdatePolicy.attemptDue(lastAttempt: date, now: date.addingTimeInterval(59), hasPartialTransfer: true))
        #expect(FirmwareUpdatePolicy.attemptDue(lastAttempt: date, now: date.addingTimeInterval(60), hasPartialTransfer: true))
    }
}
