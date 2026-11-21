import Foundation
import Testing

@testable import PaperboyCore

@Suite struct EpubBuilderTests {
    static let article = Article(
        url: "https://example.com/p/hello?x=1&y=2",
        source: "The Example <Letter> & Co",
        title: "Hello & \"welcome\" <reader>",
        author: "Jane Writer\tO'Neil",
        date: Date(timeIntervalSince1970: 1_794_744_000),
        bodyXHTML: HTMLCleaner.clean("<p>Body with R&D &amp; an <em>emphasis</em>.</p><h2>Head</h2><ul><li>one</li></ul>"))

    @Test func zipStructure() throws {
        let epub = try EpubBuilder.build(Self.article)
        let bytes = [UInt8](epub)

        // The first entry is "mimetype", stored, no extra field, so the magic string sits at offset 38.
        #expect(Array(bytes[0..<4]) == [0x50, 0x4B, 0x03, 0x04])
        #expect(Array(bytes[8..<10]) == [0, 0])  // method: stored
        #expect(Array(bytes[26..<30]) == [8, 0, 0, 0])  // name length 8, extra length 0
        #expect(String(decoding: bytes[30..<38], as: UTF8.self) == "mimetype")
        #expect(String(decoding: bytes[38..<58], as: UTF8.self) == "application/epub+zip")

        let zip = try ZipReader(epub)
        #expect(zip.entries.map(\.name) == EpubBuilder.entryNames)
        #expect(zip.entries.first?.name == "mimetype")
        for entry in zip.entries {
            #expect(entry.method == 0)
            #expect(entry.compressedSize == entry.uncompressedSize)
            let contents = try zip.contents(of: entry)  // verifies size and CRC
            #expect(CRC32.checksum(contents) == entry.crc32)
            #expect(!contents.isEmpty)
        }
        #expect(try zip.contents(named: "mimetype") == Data("application/epub+zip".utf8))
    }

    @Test func documentsAreWellFormedAndEscaped() throws {
        let zip = try ZipReader(try EpubBuilder.build(Self.article))
        for name in EpubBuilder.entryNames where name != "mimetype" {
            let text = String(decoding: try zip.contents(named: name), as: UTF8.self)
            #expect(text.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"), "\(name)")
            expectWellFormed(text, "\(name)")
        }
        let opf = String(decoding: try zip.contents(named: "OEBPS/content.opf"), as: UTF8.self)
        #expect(opf.contains("<dc:title>Hello &amp; &quot;welcome&quot; &lt;reader&gt;</dc:title>"))
        #expect(opf.contains("<dc:creator>Jane Writer O'Neil</dc:creator>"))
        #expect(opf.contains("<dc:identifier id=\"bookid\">https://example.com/p/hello?x=1&amp;y=2</dc:identifier>"))
        #expect(opf.contains("<dc:date>2026-11-15T12:00:00Z</dc:date>"))
        #expect(opf.contains("media-type=\"application/x-dtbncx+xml\""))
        #expect(opf.contains("properties=\"nav\""))
        #expect(opf.contains("<spine toc=\"ncx\">"))
        #expect(opf.contains("content=\"\(Self.article.id.hex)\""))

        let container = String(decoding: try zip.contents(named: "META-INF/container.xml"), as: UTF8.self)
        #expect(container.contains("full-path=\"OEBPS/content.opf\""))

        let chapter = String(decoding: try zip.contents(named: "OEBPS/article.xhtml"), as: UTF8.self)
        #expect(chapter.contains("<h1>Hello &amp; &quot;welcome&quot; &lt;reader&gt;</h1>"))
        #expect(chapter.contains("<p><em>Jane Writer O'Neil · The Example &lt;Letter&gt; &amp; Co · 15 November 2026</em></p>"))
        #expect(chapter.contains("<p>Body with R&amp;D &amp; an <em>emphasis</em>.</p>"))

        let ncx = String(decoding: try zip.contents(named: "OEBPS/toc.ncx"), as: UTF8.self)
        #expect(ncx.contains("<content src=\"article.xhtml\"/>"))
        let nav = String(decoding: try zip.contents(named: "OEBPS/nav.xhtml"), as: UTF8.self)
        #expect(nav.contains("epub:type=\"toc\""))
    }

    @Test func buildIsDeterministic() throws {
        let first = try EpubBuilder.build(Self.article)
        let second = try EpubBuilder.build(Self.article)
        #expect(first == second)
        var other = Self.article
        other.title = "Different"
        #expect(try EpubBuilder.build(other) != first)
    }

    @Test func emptyBodyAndEmptyMetadataStillBuild() throws {
        let article = Article(url: "", source: "", title: "  ", author: "", date: Date(timeIntervalSince1970: 0), bodyXHTML: "")
        let zip = try ZipReader(try EpubBuilder.build(article))
        for name in EpubBuilder.entryNames where name != "mimetype" {
            expectWellFormed(String(decoding: try zip.contents(named: name), as: UTF8.self), "\(name)")
        }
        let opf = String(decoding: try zip.contents(named: "OEBPS/content.opf"), as: UTF8.self)
        #expect(opf.contains("<dc:title>Untitled</dc:title>"))
        #expect(opf.contains("urn:paperboy:"))
        #expect(!opf.contains("<dc:creator>"))
    }

    @Test func passesUnzipIntegrityTest() throws {
        guard Tool.exists(Tool.unzip) else { return }
        let directory = try makeTempDirectory("paperboy-epub")
        defer { try? FileManager.default.removeItem(at: directory) }
        for (index, article) in ([Self.article] + DemoArticles.articles).enumerated() {
            let file = directory.appendingPathComponent("a\(index).epub")
            try EpubBuilder.build(article).write(to: file)
            let result = try Tool.run(Tool.unzip, ["-t", file.path])
            #expect(result.status == 0, "\(result.output)")
            #expect(result.output.contains("No errors detected"))
            #expect(result.output.contains("testing: mimetype"))

            // Extract with unzip and compare with our own reader, then lint what was extracted.
            let extracted = directory.appendingPathComponent("x\(index)")
            let unpack = try Tool.run(Tool.unzip, ["-q", "-o", file.path, "-d", extracted.path])
            #expect(unpack.status == 0, "\(unpack.output)")
            let zip = try ZipReader(try Data(contentsOf: file))
            for entry in zip.entries {
                let onDisk = try Data(contentsOf: extracted.appendingPathComponent(entry.name))
                #expect(onDisk == (try zip.contents(of: entry)), "\(entry.name)")
            }
            if Tool.exists(Tool.xmllint) {
                let files = EpubBuilder.entryNames.filter { $0 != "mimetype" }.map { extracted.appendingPathComponent($0).path }
                let lint = try Tool.run(Tool.xmllint, ["--noout"] + files)
                #expect(lint.status == 0, "\(lint.output)")
            }
        }
    }

    @Test func metadataReadsBack() throws {
        let metadata = try EpubInspector.metadata(of: try EpubBuilder.build(Self.article))
        #expect(metadata.title == "Hello & \"welcome\" <reader>")
        #expect(metadata.author == "Jane Writer O'Neil")
        #expect(metadata.publisher == "The Example <Letter> & Co")
        #expect(metadata.identifier == "https://example.com/p/hello?x=1&y=2")
        #expect(metadata.date == Date(timeIntervalSince1970: 1_794_744_000))
    }

    @Test func demoArticlesAreStableAndVaried() throws {
        let articles = DemoArticles.articles
        #expect(articles.count == 3)
        #expect(Set(articles.map(\.id)).count == 3)
        #expect(articles[0].id.hex == ArticleID(canonicalURL: "https://paperboy.invalid/demo/1").hex)
        for article in articles {
            expectWellFormedFragment(article.bodyXHTML)
            #expect(elementNames(in: article.bodyXHTML).isSubset(of: allowedElements))
        }
        // The long one must be larger than a few flow-control windows.
        #expect(try EpubBuilder.build(articles[1]).count > 3 * SyncProtocol.flowControlWindow)
        let names = articles.map { elementNames(in: $0.bodyXHTML) }.reduce(into: Set<String>()) { $0.formUnion($1) }
        #expect(names.isSuperset(of: ["p", "h2", "h3", "blockquote", "ul", "ol", "li", "em", "strong", "hr", "pre"]))
    }
}

@Suite struct ZipReaderTests {
    @Test func rejectsGarbage() {
        #expect(throws: ZipReader.ZipReadError.notAZip) { try ZipReader(Data()) }
        #expect(throws: ZipReader.ZipReadError.notAZip) { try ZipReader(Data(repeating: 0x41, count: 500)) }
    }

    @Test func detectsCorruption() throws {
        var epub = try EpubBuilder.build(EpubBuilderTests.article)
        // Flip a byte in the last entry's data (just before the central directory).
        let zip = try ZipReader(epub)
        let last = try #require(zip.entries.last)
        let index = last.localHeaderOffset + 30 + last.name.utf8.count + 10
        epub[index] ^= 0xFF
        let damaged = try ZipReader(epub)
        #expect(throws: ZipReader.ZipReadError.crcMismatch("OEBPS/article.xhtml")) { try damaged.contents(named: "OEBPS/article.xhtml") }
    }

    @Test func readsDeflatedEntriesWrittenByZip() throws {
        // An archive made by /usr/bin/zip uses deflate; the CLI must be able to read such EPUBs.
        let zipTool = "/usr/bin/zip"
        guard Tool.exists(zipTool) else { return }
        let directory = try makeTempDirectory("paperboy-zip")
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = String(repeating: "compress me, please. ", count: 400)
        try Data(text.utf8).write(to: directory.appendingPathComponent("big.txt"))
        let archive = directory.appendingPathComponent("out.zip")
        let result = try Tool.run(zipTool, ["-j", "-q", archive.path, directory.appendingPathComponent("big.txt").path])
        #expect(result.status == 0, "\(result.output)")
        let zip = try ZipReader(try Data(contentsOf: archive))
        let entry = try #require(zip.entry(named: "big.txt"))
        #expect(entry.method == 8)
        #expect(String(decoding: try zip.contents(of: entry), as: UTF8.self) == text)
    }
}
