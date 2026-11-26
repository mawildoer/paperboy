import CryptoKit
import Foundation
import PaperboyCore

struct FirmwareRelease: Sendable {
    let version: String
    let image: Data

    /// Release assets and their digest come from the project's HTTPS GitHub release.
    static func latest() async throws -> FirmwareRelease {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        struct Release: Decodable { let tag_name: String; let assets: [Asset] }
        let api = URL(string: "https://api.github.com/repos/mawildoer/crosspoint-reader/releases/latest")!
        let metadata = try await download(api, maximum: 200_000)
        let release = try JSONDecoder().decode(Release.self, from: metadata)
        guard release.tag_name.hasPrefix("paperboy-v"),
              String(release.tag_name.dropFirst("paperboy-v".count)).compare("0.2.0", options: .numeric) != .orderedAscending,
              let binary = release.assets.first(where: { $0.name == "paperboy-x3-update.bin" }),
              let sums = release.assets.first(where: { $0.name == "SHA256SUMS" }) else { throw URLError(.cannotParseResponse) }
        let digestText = String(decoding: try await download(sums.browser_download_url, maximum: 10_000), as: UTF8.self)
        guard let line = digestText.split(separator: "\n").first(where: { $0.split(whereSeparator: \.isWhitespace).last == "paperboy-x3-update.bin" }),
              let digest = line.split(whereSeparator: \.isWhitespace).first, digest.count == 64 else { throw URLError(.cannotParseResponse) }
        let image = try await download(binary.browser_download_url, maximum: FirmwareUpdateSession.maximumBytes)
        let actual = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
        guard actual == digest.lowercased() else { throw SyncError.dataSource("downloaded firmware checksum does not match the release") }
        return FirmwareRelease(version: String(release.tag_name.dropFirst("paperboy-v".count)) + "-paperboy", image: image)
    }

    private static func download(_ url: URL, maximum: Int) async throws -> Data {
        guard url.scheme == "https", url.host == "github.com" || url.host == "api.github.com" else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, response.url?.scheme == "https" else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximum else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return data
    }
}
