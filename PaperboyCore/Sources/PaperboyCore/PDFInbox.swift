import CryptoKit
import Foundation

/// Copies a provider's temporary file while it is still valid; decoding/OCR belongs in the main app.
public enum PDFInbox {
    public static let maxBytes = 20 * 1024 * 1024

    public enum Failure: Error, LocalizedError {
        case tooLarge, notPDF, invalidFilename
        public var errorDescription: String? {
            switch self {
            case .tooLarge: return "This PDF is larger than the 20 MB import limit."
            case .notPDF: return "The shared file is not a readable PDF."
            case .invalidFilename: return "The queued PDF filename is invalid."
            }
        }
    }

    public static func hasPDFHeader(_ data: Data) -> Bool {
        data.prefix(1024).range(of: Data("%PDF-".utf8)) != nil
    }

    @discardableResult
    public static func queueFile(at source: URL, container: URL, title: String? = nil, now: Date = Date()) throws -> SharedPage {
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maxBytes else { throw Failure.tooLarge }
        let inbox = container.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let token = UUID().uuidString
        let temporary = inbox.appendingPathComponent(token + ".partial")
        let destination = inbox.appendingPathComponent(token + ".pdf")
        let record = inbox.appendingPathComponent(token + ".json")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        var committed = false
        defer {
            try? FileManager.default.removeItem(at: temporary)
            if !committed { try? FileManager.default.removeItem(at: destination) }
        }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        var hash = SHA256()
        var count = 0
        var header = Data()
        while let data = try input.read(upToCount: 256 * 1024), !data.isEmpty {
            count += data.count
            guard count <= maxBytes else { throw Failure.tooLarge }
            if header.count < 1024 { header.append(data.prefix(1024 - header.count)) }
            hash.update(data: data)
            try output.write(contentsOf: data)
        }
        guard hasPDFHeader(header) else { throw Failure.notPDF }
        try output.synchronize()
        try output.close()
        try FileManager.default.moveItem(at: temporary, to: destination)
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        let name = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let page = SharedPage(
            url: "paperboy-pdf://\(digest)", title: name?.isEmpty == false ? name : source.deletingPathExtension().lastPathComponent,
            sharedAt: now, pdfFile: destination.lastPathComponent)
        try JSONEncoder().encode(page).write(to: record, options: .atomic)
        committed = true
        return page
    }

    public static func fileURL(named filename: String, container: URL) throws -> URL {
        guard filename.hasSuffix(".pdf"), UUID(uuidString: String(filename.dropLast(4))) != nil,
            !filename.contains("/"), !filename.contains("\\")
        else { throw Failure.invalidFilename }
        let file = container.appendingPathComponent("Inbox", isDirectory: true).appendingPathComponent(filename)
        guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw Failure.invalidFilename }
        return file
    }
}
