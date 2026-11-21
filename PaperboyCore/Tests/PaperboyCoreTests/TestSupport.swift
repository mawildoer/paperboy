import Foundation
import Testing

@testable import PaperboyCore

enum Tool {
    static let xmllint = "/usr/bin/xmllint"
    static let unzip = "/usr/bin/unzip"

    static func exists(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    /// Run a tool; returns (exit status, combined output).
    static func run(_ path: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

func makeTempDirectory(_ name: String = "paperboy-tests") throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Well-formedness check with a real XML parser (Foundation's, which is libxml2) and, when it
/// is installed, with `xmllint --noout` as an independent second opinion.
func expectWellFormed(_ document: String, _ comment: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
    let parser = XMLParser(data: Data(document.utf8))
    let ok = parser.parse()
    #expect(ok, "XMLParser rejected the document: \(String(describing: parser.parserError)) \(comment ?? "")\n\(document.prefix(600))", sourceLocation: sourceLocation)
    guard Tool.exists(Tool.xmllint) else { return }
    do {
        let directory = try makeTempDirectory("paperboy-xml")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("doc.xml")
        try Data(document.utf8).write(to: file)
        let result = try Tool.run(Tool.xmllint, ["--noout", file.path])
        #expect(result.status == 0, "xmllint: \(result.output)", sourceLocation: sourceLocation)
    } catch {
        Issue.record("could not run xmllint: \(error)", sourceLocation: sourceLocation)
    }
}

/// Wrap a cleaned fragment in a root element and check it.
func expectWellFormedFragment(_ fragment: String, sourceLocation: SourceLocation = #_sourceLocation) {
    expectWellFormed("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<body>\n\(fragment)</body>\n", sourceLocation: sourceLocation)
}

/// Element names used in a fragment.
func elementNames(in fragment: String) -> Set<String> {
    final class Collector: NSObject, XMLParserDelegate {
        var names = Set<String>()
        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
            attributes: [String: String]
        ) {
            names.insert(elementName)
        }
    }
    let collector = Collector()
    let parser = XMLParser(data: Data("<body>\(fragment)</body>".utf8))
    parser.delegate = collector
    parser.parse()
    collector.names.remove("body")
    return collector.names
}

let allowedElements: Set<String> = [
    "p", "h1", "h2", "h3", "h4", "blockquote", "ul", "ol", "li", "em", "i", "strong", "b", "a", "br", "hr", "pre", "code",
]
