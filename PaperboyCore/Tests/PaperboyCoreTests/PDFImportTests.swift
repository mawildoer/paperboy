import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import Testing

@testable import PaperboyCore

@Suite struct PDFImportTests {
    static func document(pages: Int = 1, scanned: Bool = false) throws -> Data {
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data))
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(
            CGContext(
                consumer: consumer, mediaBox: &box,
                [kCGPDFContextTitle: "Research paper"] as CFDictionary))
        for _ in 0..<pages {
            context.beginPDFPage(nil)
            if scanned {
                let chart = try ImagePipelineTests.chart()
                let source = try #require(CGImageSourceCreateWithData(chart as CFData, nil))
                let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
                context.draw(image, in: CGRect(x: 0, y: 200, width: 612, height: 357))
            } else {
                let text = "Research results: output rose from 100 to 120. The chart and source labels must survive import."
                context.textPosition = CGPoint(x: 40, y: 720)
                let attrs: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 11, nil)
                ]
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs)), context)
                context.setStrokeColor(CGColor(red: 0, green: 0.3, blue: 0.9, alpha: 1))
                context.setLineWidth(2)
                context.move(to: CGPoint(x: 50, y: 100))
                context.addLine(to: CGPoint(x: 500, y: 400))
                context.strokePath()
            }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    @Test func nativePDFHasReflowTextAndMonochromePageImages() throws {
        let article = try PDFImporter.article(data: Self.document(pages: 2), url: "paperboy-pdf://fixture")
        #expect(article.title == "Research paper")
        #expect(article.bodyXHTML.contains("output rose from 100 to 120"))
        #expect(article.bodyXHTML.contains("Page 2"))
        #expect(article.images.count == 2)
        #expect(article.images.allSatisfy { $0.data[24] == 1 && $0.data[25] == 0 })
        let zip = try ZipReader(EpubBuilder.build(article))
        #expect(try zip.contents(named: "OEBPS/images/pdf-page-2.png") == article.images[1].data)
        expectWellFormed(String(decoding: try zip.contents(named: "OEBPS/article.xhtml"), as: UTF8.self))
    }

    @Test func scannedPDFUsesLocalOCRWithoutDroppingThePage() throws {
        let data = try Self.document(scanned: true)
        #expect(PDFDocument(data: data)?.page(at: 0)?.string?.isEmpty != false)
        let article: Article
        do {
            article = try PDFImporter.article(data: data, url: "paperboy-pdf://scan")
        } catch {
            let details = error as NSError
            Issue.record("Local OCR failed: \(details.domain) \(details.code): \(details.localizedDescription); \(details.userInfo)")
            return
        }
        #expect(article.images.count == 1)
        #expect(article.bodyXHTML.localizedCaseInsensitiveContains("Quarterly"))
    }

    @Test func PDFQueueCopiesTemporaryFileAndKeepsStableIdentity() throws {
        let dir = try makeTempDirectory("paperboy-pdf")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("original.pdf")
        let content = try Self.document()
        try content.write(to: source)
        let first = try PDFInbox.queueFile(at: source, container: dir, title: "My report", now: Date(timeIntervalSince1970: 1_700_000_000.25))
        let second = try PDFInbox.queueFile(at: source, container: dir, title: "Renamed report")
        try FileManager.default.removeItem(at: source)
        #expect(first.url == second.url)
        #expect(first.pdfFile != second.pdfFile)
        let file = try PDFInbox.fileURL(named: #require(first.pdfFile), container: dir)
        #expect(try Data(contentsOf: file) == content)
        let encoded = try JSONEncoder().encode(first)
        #expect(try JSONDecoder().decode(SharedPage.self, from: encoded) == first)
        #expect(throws: PDFInbox.Failure.self) { try PDFInbox.fileURL(named: "../other.pdf", container: dir) }
    }

    @Test func invalidLargeAndLongPDFsAreRejectedWithoutTruncation() throws {
        #expect(throws: PDFImporter.Failure.self) { try PDFImporter.article(data: Data("not PDF".utf8), url: "paperboy-pdf://bad") }
        #expect(throws: PDFImporter.Failure.self) {
            try PDFImporter.article(data: Self.document(pages: PDFImporter.maxPages + 1), url: "paperboy-pdf://long")
        }
        let dir = try makeTempDirectory("paperboy-pdf-size")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("large.pdf")
        #expect(FileManager.default.createFile(atPath: file.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(PDFInbox.maxBytes + 1))
        try handle.close()
        #expect(throws: PDFInbox.Failure.self) { try PDFInbox.queueFile(at: file, container: dir) }
    }
}
