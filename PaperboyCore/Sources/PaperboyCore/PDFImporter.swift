import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Vision

/// Text reflows on the reader; page images preserve plots/tables exactly as rendered, without cloud processing.
public enum PDFImporter {
    public static let maxPages = 20
    public enum Failure: Error, LocalizedError {
        case invalid, locked, copyingRestricted, tooManyPages, unreadablePage(Int), imageBudget
        public var errorDescription: String? {
            switch self {
            case .invalid: return "This file is not a readable PDF."
            case .locked: return "Unlock the PDF before sharing it to Paperboy."
            case .copyingRestricted: return "This PDF does not permit text copying."
            case .tooManyPages: return "PDF imports currently support up to 20 pages. Split this document into smaller PDFs."
            case .unreadablePage(let page): return "PDF page \(page) could not be rendered."
            case .imageBudget: return "This PDF needs more image data than the reader import budget allows. Try a smaller document."
            }
        }
    }

    /// Run on a worker task: PDFKit, rendering and Vision perform synchronous work.
    public static func article(data: Data, url: String, title: String? = nil, now: Date = Date()) throws -> Article {
        guard data.count <= PDFInbox.maxBytes else { throw PDFInbox.Failure.tooLarge }
        guard PDFInbox.hasPDFHeader(data), let document = PDFDocument(data: data) else { throw Failure.invalid }
        guard !document.isLocked else { throw Failure.locked }
        guard document.allowsCopying else { throw Failure.copyingRestricted }
        guard document.pageCount > 0 else { throw Failure.invalid }
        guard document.pageCount <= maxPages else { throw Failure.tooManyPages }
        guard let provider = CGDataProvider(data: data as CFData), let drawing = CGPDFDocument(provider) else { throw Failure.invalid }
        let metadata = document.documentAttributes ?? [:]
        let pdfTitle = (metadata[PDFDocumentAttribute.titleAttribute] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosenTitle = [pdfTitle, title].compactMap { $0 }.first(where: { !$0.isEmpty }) ?? "Shared PDF"
        var article = Article(
            url: url, source: "PDF", title: chosenTitle,
            author: metadata[PDFDocumentAttribute.authorAttribute] as? String ?? "", date: now, bodyXHTML: "")
        var parts: [String] = []
        var used = 0
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            let section: (String, ArticleImage) = try autoreleasepool {
                guard let page = document.page(at: index), let pdfPage = drawing.page(at: index + 1) else {
                    throw Failure.unreadablePage(index + 1)
                }
                let image = try render(pdfPage, number: index + 1)
                let original = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let text = original.filter { $0.isLetter || $0.isNumber }.count >= 30 ? original : try recognize(image)
                let buffer = NSMutableData()
                guard let output = CGImageDestinationCreateWithData(buffer, "public.png" as CFString, 1, nil) else {
                    throw Failure.unreadablePage(index + 1)
                }
                CGImageDestinationAddImage(output, image, nil)
                guard CGImageDestinationFinalize(output) else { throw Failure.unreadablePage(index + 1) }
                let asset = try MonochromeImage.encode(buffer as Data, path: "images/pdf-page-\(index + 1).png", preferChart: true)
                var html = "<h2>Page \(index + 1)</h2>\n<p><img src=\"\(asset.path)\" alt=\"PDF page \(index + 1)\"/></p>\n"
                // Newlines become paragraphs so columns and math are not joined into a single long line.
                for line in text.components(separatedBy: .newlines) {
                    let content = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !content.isEmpty { html += "<p>\(HTMLCleaner.escape(content))</p>\n" }
                }
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    html += "<p>No readable text was found on this page; its image is preserved above.</p>\n"
                }
                return (html, asset)
            }
            used += section.1.data.count
            guard used <= 512 * 1024 else { throw Failure.imageBudget }
            parts.append(section.0)
            article.images.append(section.1)
        }
        article.bodyXHTML = parts.joined(separator: "\n")
        return article
    }

    private static func render(_ page: CGPDFPage, number: Int) throws -> CGImage {
        let bounds = page.getBoxRect(.cropBox)
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
            throw Failure.unreadablePage(number)
        }
        let rotated = abs(page.rotationAngle) % 180 == 90
        let w = rotated ? bounds.height : bounds.width
        let h = rotated ? bounds.width : bounds.height
        let scale = min(1056 / w, 1584 / h)
        let width = max(1, Int((w * scale).rounded()))
        let height = max(1, Int((h * scale).rounded()))
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw Failure.unreadablePage(number) }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { throw Failure.unreadablePage(number) }
        return image
    }

    private static func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        request.preferBackgroundProcessing = true
        #if os(macOS)
        func performOnCPU() throws {
            // Device discovery also initializes the recognition backend.
            for (stage, devices) in try request.supportedComputeStageDevices {
                if let cpu = devices.first(where: { device in
                    if case .cpu = device { return true }
                    return false
                }) {
                    request.setComputeDevice(cpu, for: stage)
                }
            }
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        }
        do {
            try performOnCPU()
        } catch {
            // macOS 27 can fail inside its accurate TextRecognition backend.
            // Retry locally with Vision's fast engine; other errors still propagate.
            guard (error as NSError).domain == "TextRecognition.CRImageReaderError" else { throw error }
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = false
            try performOnCPU()
        }
        #else
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        #endif
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
