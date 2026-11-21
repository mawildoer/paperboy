import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing

@testable import PaperboyCore

@Suite struct ImagePipelineTests {
    static func chart() throws -> Data {
        let context = try #require(
            CGContext(
                data: nil, width: 1200, height: 700, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 700))
        func text(_ value: String, x: Double, y: Double, size: Double = 22) {
            context.textPosition = CGPoint(x: x, y: y)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, size, nil)
            ]
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attributes)), context)
        }
        text("Quarterly output: indexed to 100", x: 90, y: 640, size: 30)
        for n in 0..<5 {
            let y = Double(120 + n * 100)
            context.setStrokeColor(CGColor(gray: 0.85, alpha: 1))
            context.setLineWidth(1)
            context.move(to: CGPoint(x: 100, y: y))
            context.addLine(to: CGPoint(x: 1100, y: y))
            context.strokePath()
            text("\(80+n*10)", x: 40, y: y - 6)
            text("Q\(n+1)", x: Double(100 + n * 240), y: 65)
        }
        for (color, offset) in [
            (CGColor(red: 0.1, green: 0.3, blue: 0.8, alpha: 1), 0.0), (CGColor(red: 1, green: 0.75, blue: 0, alpha: 1), 70.0),
        ] {
            context.setStrokeColor(color)
            context.setLineWidth(3)
            for n in 0..<5 {
                let point = CGPoint(x: Double(100 + n * 240), y: Double(160 + n * 65) + offset)
                if n == 0 { context.move(to: point) } else { context.addLine(to: point) }
            }
            context.strokePath()
        }
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    @Test func compactOneBitChartRoundTripsAndPackages() throws {
        let original = try Self.chart()
        let image = try MonochromeImage.encode(original, path: "images/image-0.png", preferChart: true)
        #expect(image.width == 1056)
        #expect(image.data.count < 96 * 1024)
        #expect(image.data[24] == 1)  // actual PNG depth, not an 8-bit image containing two colors
        #expect(image.data[25] == 0)  // grayscale
        let source = try #require(CGImageSourceCreateWithData(image.data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == image.width)
        #expect(decoded.height == image.height)
        var article = Article(
            url: "https://example.com/chart", source: "Example", title: "Chart", author: "", date: Date(timeIntervalSince1970: 0),
            bodyXHTML: "<p><img src=\"images/image-0.png\" alt=\"Output chart\"/></p>")
        article.images = [image]
        let zip = try ZipReader(EpubBuilder.build(article))
        #expect(try zip.contents(named: "OEBPS/images/image-0.png") == image.data)
        let opf = String(decoding: try zip.contents(named: "OEBPS/content.opf"), as: UTF8.self)
        #expect(opf.contains("media-type=\"image/png\""))
        expectWellFormed(String(decoding: try zip.contents(named: "OEBPS/article.xhtml"), as: UTF8.self))
        if let dir = ProcessInfo.processInfo.environment["PAPERBOY_IMAGE_PREVIEW"] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try original.write(to: URL(fileURLWithPath: dir).appendingPathComponent("chart-original.png"))
            try image.data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("chart-monochrome.png"))
        }
    }

    @Test func furnitureIsExcludedWhileFigureAndCaptionStay() throws {
        let html = """
            <article><p>Real article content.</p><div class="read-next"><p>Read next</p><img src="/ad.png"></div>
            <figure><picture><img data-src="/plot.png" src="data:image/gif;base64,R0" alt="Inflation chart $100 &amp; change"></picture><figcaption>Data: the source</figcaption></figure>
            <aside>Ads</aside><footer>Legal links</footer><p hidden>Invisible</p></article>
            """
        let result = HTMLCleaner.cleanWithImages(html, baseURL: "https://example.com/story")
        #expect(result.sources.count == 1)
        #expect(result.sources[0].url.absoluteString == "https://example.com/plot.png")
        #expect(result.sources[0].likelyChart)
        #expect(!result.xhtml.contains("Read next"))
        #expect(!result.xhtml.contains("Invisible"))
        #expect(result.xhtml.contains("Data: the source"))
        var article = Article(url: "https://example.com", source: "", title: "", author: "", date: Date(), bodyXHTML: result.xhtml)
        article.imageSources = result.sources
        let zip = try ZipReader(EpubBuilder.build(article))
        let chapter = String(decoding: try zip.contents(named: "OEBPS/article.xhtml"), as: UTF8.self)
        #expect(!chapter.contains("<img"))
        #expect(chapter.contains("$100 &amp; change"))
    }

    @Test func photosUseSmallDitheredBitmaps() throws {
        let context = try #require(
            CGContext(
                data: nil, width: 640, height: 480, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
        let pixels = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, pixels, nil)
        #expect(CGImageDestinationFinalize(destination))
        let output = try MonochromeImage.encode(data as Data, path: "images/photo.png", preferChart: false)
        #expect(output.width == 320)
        #expect(output.data.count <= 24 * 1024)
        #expect(output.data[24] == 1)
        #expect(CGImageSourceCreateWithData(output.data as CFData, nil) != nil)
    }

    @Test func dataURLImagesArePreparedBeforeTransport() async throws {
        let png = try Self.chart()
        let html = "<p>Article with a chart.</p><img src=\"data:image/png;base64,\(png.base64EncodedString())\" alt=\"Chart\"/>"
        let cleaned = HTMLCleaner.cleanWithImages(html, baseURL: "https://example.com/story")
        var article = Article(url: "https://example.com/story", source: "", title: "", author: "", date: Date(), bodyXHTML: cleaned.xhtml)
        article.imageSources = cleaned.sources
        let result = await ArticleImagePipeline.prepare(article)
        #expect(result.images.count == 1)
        #expect(result.imageSources.isEmpty)
        #expect(result.images.first?.data[24] == 1)
        #expect(result.bodyXHTML.contains("images/image-0.png"))
    }

    @Test func choosesHighResolutionSourceAndRejectsTrackingPixels() {
        let result = HTMLCleaner.cleanWithImages(
            "<img src=\"small.png\" srcset=\"large.png 1200w, medium.png 600w\" alt=\"A chart\"><img src=\"track.png\" width=\"1\" height=\"1\">",
            baseURL: "https://example.com/")
        #expect(result.sources.count == 1)
        #expect(result.sources.first?.url.absoluteString == "https://example.com/large.png")
    }

    @Test @MainActor func realWebKitReaderExtractsWithoutPublisherScripts() async throws {
        let paragraph =
            "<p>The researchers measured household spending and compared the resulting observations across five quarters. This article explains the evidence, limitations, and methods used in the analysis. Its figures illustrate the observed relationship and provide enough context to interpret it correctly.</p>"
        let html =
            "<html><head><title>A study</title></head><body><article>\(String(repeating: paragraph, count: 4))<img src=\"/chart.png\" alt=\"Output plot\"><div class=\"read-next\">Unrelated content</div></article><script>document.body.innerHTML='executed';</script></body></html>"
        let article = try await ReaderModeExtractor().article(html: html, url: "https://example.com/story")
        #expect(article.bodyXHTML.contains("methods used"))
        #expect(!article.bodyXHTML.contains("Unrelated content"))
        #expect(article.imageSources.count == 1)
    }

    @Test func invalidInputsAndUnsafePathsAreRejected() throws {
        #expect(throws: MonochromeImage.Failure.self) {
            try MonochromeImage.encode(Data("not an image".utf8), path: "images/x.png", preferChart: false)
        }
        let image = try MonochromeImage.encode(Self.chart(), path: "../escape.png", preferChart: true)
        var article = Article(url: "", source: "", title: "", author: "", date: Date(), bodyXHTML: "<p>Text</p>")
        article.images = [image]
        #expect(throws: EpubBuilder.Failure.self) { try EpubBuilder.build(article) }
    }
}
