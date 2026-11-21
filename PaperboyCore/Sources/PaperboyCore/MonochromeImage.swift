import Compression
import CoreGraphics
import Foundation
import ImageIO

/// Lossless 1-bit PNG: chart colors become dark ink; photos use a coarse ordered screen.
public enum MonochromeImage {
    public enum Failure: Error { case unsupported, tooLarge, encoding }
    public static func encode(_ data: Data, path: String, preferChart: Bool) throws -> ArticleImage {
        guard data.count <= 6_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let sw = properties[kCGImagePropertyPixelWidth] as? Int,
            let sh = properties[kCGImagePropertyPixelHeight] as? Int,
            sw >= 48, sh >= 32, sw <= 50_000, sh <= 50_000, sw <= 40_000_000 / sh
        else { throw Failure.unsupported }
        guard
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1584,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary)
        else { throw Failure.unsupported }
        // A white/pale background and sparse ink are characteristic of plots and diagrams.
        let sample = try pixels(thumbnail, width: 64, height: 64)
        let pale = stride(from: 0, to: sample.count, by: 4).filter { min(sample[$0], sample[$0 + 1], sample[$0 + 2]) > 235 }.count
        let chart = preferChart || pale > 64 * 64 / 2
        var width = min(thumbnail.width, chart ? 1056 : 320)
        for _ in 0..<5 {
            let height = max(1, Int(Double(thumbnail.height) * Double(width) / Double(thumbnail.width)))
            let rgba = try pixels(thumbnail, width: width, height: height)
            let png = try encodePixels(rgba, width: width, height: height, chart: chart)
            if png.count <= (chart ? 96 * 1024 : 24 * 1024) {
                return ArticleImage(path: path, data: png, width: width, height: height)
            }
            width = Int(Double(width) * 0.8)
        }
        throw Failure.tooLarge
    }

    private static func pixels(_ image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        let ok = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard
                let context = CGContext(
                    data: raw.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { throw Failure.encoding }
        return rgba
    }

    private static func encodePixels(_ rgba: [UInt8], width: Int, height: Int, chart: Bool) throws -> Data {
        let stride = (width + 7) / 8
        var scanlines = [UInt8](repeating: 0, count: (stride + 1) * height)
        let screen = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]
        let dark = Swift.stride(from: 0, to: rgba.count, by: 4).filter { rgba[$0] < 70 && rgba[$0 + 1] < 70 && rgba[$0 + 2] < 70 }.count
        let invert = chart && dark > width * height * 3 / 5
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                var level =
                    chart
                    ? Int(min(rgba[i], rgba[i + 1], rgba[i + 2]))
                    : (Int(rgba[i]) * 299 + Int(rgba[i + 1]) * 587 + Int(rgba[i + 2]) * 114) / 1000
                if invert { level = 255 - level }
                let threshold = chart ? 205 : screen[(y % 4) * 4 + x % 4] * 16 + 8
                if level >= threshold { scanlines[y * (stride + 1) + 1 + x / 8] |= 1 << (7 - x % 8) }
            }
        }
        // Compression's ZLIB codec emits raw DEFLATE; PNG needs a zlib header and Adler-32.
        var compressed = [UInt8](repeating: 0, count: scanlines.count + scanlines.count / 8 + 1024)
        let count = compressed.withUnsafeMutableBufferPointer { dst in
            scanlines.withUnsafeBufferPointer { src in
                compression_encode_buffer(dst.baseAddress!, dst.count, src.baseAddress!, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard count > 0 else { throw Failure.encoding }
        var zlib = Data([0x78, 0x9c])
        zlib.append(contentsOf: compressed.prefix(count))
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in scanlines {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        zlib.append(contentsOf: be((b << 16) | a))
        var png = Data([137, 80, 78, 71, 13, 10, 26, 10])
        chunk("IHDR", payload: Data(be(UInt32(width)) + be(UInt32(height)) + [1, 0, 0, 0, 0]), into: &png)
        chunk("IDAT", payload: zlib, into: &png)
        chunk("IEND", payload: Data(), into: &png)
        return png
    }

    private static func be(_ n: UInt32) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: n >> 24), UInt8(truncatingIfNeeded: n >> 16), UInt8(truncatingIfNeeded: n >> 8),
            UInt8(truncatingIfNeeded: n),
        ]
    }
    private static func chunk(_ type: String, payload: Data, into png: inout Data) {
        var bytes = Data(type.utf8)
        bytes.append(payload)
        png.append(contentsOf: be(UInt32(payload.count)))
        png.append(bytes)
        png.append(contentsOf: be(CRC32.checksum(bytes)))
    }
}

/// Image downloads are bounded, sequential and optional; article text always survives a failed image.
public enum ArticleImagePipeline {
    public static func prepare(_ input: Article) async -> Article {
        var article = input
        var used = article.images.reduce(0) { $0 + $1.data.count }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.httpCookieStorage = HTTPCookieStorage.shared
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let deadline = Date().addingTimeInterval(25)
        for source in article.imageSources.prefix(12) {
            if Task.isCancelled || Date() >= deadline { break }
            do {
                let data: Data
                if source.url.scheme == "data" {
                    let value = source.url.absoluteString
                    guard value.hasPrefix("data:image/"), let comma = value.firstIndex(of: ","),
                        value[..<comma].contains(";base64"), let decoded = Data(base64Encoded: String(value[value.index(after: comma)...])),
                        decoded.count <= 6_000_000
                    else { throw MonochromeImage.Failure.unsupported }
                    data = decoded
                } else {
                    let (bytes, response) = try await session.bytes(from: source.url)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                        response.expectedContentLength <= 6_000_000
                    else { throw MonochromeImage.Failure.tooLarge }
                    var downloaded = Data()
                    for try await byte in bytes {
                        if downloaded.count >= 6_000_000 { throw MonochromeImage.Failure.tooLarge }
                        if downloaded.count % 65536 == 0 {
                            try Task.checkCancellation()
                            if Date() >= deadline { throw URLError(.timedOut) }
                        }
                        downloaded.append(byte)
                    }
                    data = downloaded
                }
                let image = try MonochromeImage.encode(data, path: source.path, preferChart: source.likelyChart)
                guard used + image.data.count <= 512 * 1024 else { throw MonochromeImage.Failure.tooLarge }
                used += image.data.count
                article.images.append(image)
            } catch {
                // Missing/unsupported images keep their alt text instead of a broken EPUB reference.
            }
        }
        article.bodyXHTML = ArticleImageMarkup.resolving(article)
        article.imageSources = []
        return article
    }
}
