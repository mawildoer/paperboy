import CryptoKit
import Foundation

public enum FirmwareUpdatePolicy {
    public static let checkInterval: TimeInterval = 6 * 60 * 60
    public static let retryInterval: TimeInterval = 60 * 60

    public static func attemptDue(lastAttempt: Date?, now: Date = Date(), hasPartialTransfer: Bool = false) -> Bool {
        guard let lastAttempt else { return true }
        return now < lastAttempt || now.timeIntervalSince(lastAttempt) >= (hasPartialTransfer ? 60 : retryInterval)
    }

    /// Automatic updates only advance a recognized stable Paperboy version.
    public static func isUpgrade(_ release: String, from installed: String) -> Bool {
        guard let candidate = numbers(release), let current = numbers(installed) else { return false }
        return current.lexicographicallyPrecedes(candidate)
    }

    static func numbers(_ version: String) -> [Int]? {
        guard version.hasSuffix("-paperboy") else { return nil }
        let parts = version.dropLast("-paperboy".count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var result: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(part) else { return nil }
            result.append(value)
        }
        return result
    }
}

public struct FirmwareReleaseInfo: Codable, Equatable, Sendable {
    public let version: String
    public let digest: String
    public let imageURL: URL

    public init(version: String, digest: String, imageURL: URL) {
        self.version = version
        self.digest = digest
        self.imageURL = imageURL
    }

    var valid: Bool {
        guard let numbers = FirmwareUpdatePolicy.numbers(version), !numbers.lexicographicallyPrecedes([0, 2, 0]) else { return false }
        return digest.count == 64 &&
        digest.allSatisfy { $0.isASCII && $0.isHexDigit } && FirmwareRepository.allowed(imageURL)
    }
}

/// Release metadata and one verified image persist across scheduled background runs.
public actor FirmwareRepository {
    private struct CachedMetadata: Codable { let checked: Date; let release: FirmwareReleaseInfo }
    private let directory: URL
    private let session: URLSession

    public init(directory: URL, session: URLSession = .shared) {
        self.directory = directory
        self.session = session
    }

    public func latestMetadata(now: Date = Date(), force: Bool = false) async throws -> FirmwareReleaseInfo {
        let metadataURL = directory.appendingPathComponent("release.json")
        if !force,
           let size = try? metadataURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 200_000,
           let data = try? Data(contentsOf: metadataURL),
           let cached = try? JSONDecoder().decode(CachedMetadata.self, from: data), cached.release.valid,
           now >= cached.checked, now.timeIntervalSince(cached.checked) < FirmwareUpdatePolicy.checkInterval {
            return cached.release
        }
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        struct Release: Decodable { let tag_name: String; let assets: [Asset] }
        let api = URL(string: "https://api.github.com/repos/mawildoer/crosspoint-reader/releases/latest")!
        let release = try JSONDecoder().decode(Release.self, from: await download(api, maximum: 200_000))
        guard release.tag_name.hasPrefix("paperboy-v"),
              let binary = release.assets.first(where: { $0.name == "paperboy-x3-update.bin" }),
              let sums = release.assets.first(where: { $0.name == "SHA256SUMS" }) else { throw URLError(.cannotParseResponse) }
        let version = String(release.tag_name.dropFirst("paperboy-v".count)) + "-paperboy"
        let text = String(decoding: try await download(sums.browser_download_url, maximum: 10_000), as: UTF8.self)
        guard let line = text.split(separator: "\n").first(where: { $0.split(whereSeparator: \.isWhitespace).last == "paperboy-x3-update.bin" }),
              let digest = line.split(whereSeparator: \.isWhitespace).first else { throw URLError(.cannotParseResponse) }
        let info = FirmwareReleaseInfo(version: version, digest: digest.lowercased(), imageURL: binary.browser_download_url)
        guard info.valid else { throw URLError(.cannotParseResponse) }
        try Task.checkCancellation()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(CachedMetadata(checked: now, release: info)) {
            try? data.write(to: metadataURL, options: .atomic)
        }
        return info
    }

    public func image(for release: FirmwareReleaseInfo) async throws -> Data {
        guard release.valid else { throw URLError(.cannotParseResponse) }
        let url = directory.appendingPathComponent("firmware-\(release.digest).bin")
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= FirmwareUpdateSession.maximumBytes,
           let data = try? Data(contentsOf: url, options: .mappedIfSafe), validImage(data, release: release) { return data }
        let data = try await download(release.imageURL, maximum: FirmwareUpdateSession.maximumBytes)
        guard validImage(data, release: release) else { throw SyncError.dataSource("downloaded firmware checksum or image is invalid") }
        try Task.checkCancellation()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            where file.lastPathComponent.hasPrefix("firmware-") && file.pathExtension == "bin" && file.lastPathComponent != url.lastPathComponent {
            try? FileManager.default.removeItem(at: file)
        }
        return data
    }

    private func validImage(_ data: Data, release: FirmwareReleaseInfo) -> Bool {
        guard (256...FirmwareUpdateSession.maximumBytes).contains(data.count), data.first == 0xE9 else { return false }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == release.digest
    }

    static func allowed(_ url: URL) -> Bool {
        url.scheme == "https" && (url.host == "github.com" || url.host == "api.github.com")
    }

    private func download(_ url: URL, maximum: Int) async throws -> Data {
        guard Self.allowed(url) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, response.url?.scheme == "https" else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximum else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return data
    }
}
