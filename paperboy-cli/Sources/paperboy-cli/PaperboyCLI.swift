import Foundation
import PaperboyBLE
import PaperboyCore

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Parsed command line: a command, positional arguments, and options.
struct Arguments {
    var command = ""
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    static let valueOptions: Set<String> = ["--title", "--source", "--author", "--url", "--device", "--seconds", "--timeout", "--mtu"]
    static let flagOptions: Set<String> = ["--verbose", "-v", "--fake", "--help", "-h"]

    init(_ raw: [String]) throws {
        var index = 0
        while index < raw.count {
            let argument = raw[index]
            if Self.valueOptions.contains(argument) {
                guard index + 1 < raw.count else { throw CLIError("\(argument) needs a value") }
                options[argument] = raw[index + 1]
                index += 2
                continue
            }
            if Self.flagOptions.contains(argument) {
                flags.insert(argument)
            } else if argument.hasPrefix("-"), argument.count > 1 {
                throw CLIError("unknown option \(argument)")
            } else if command.isEmpty {
                command = argument
            } else {
                positional.append(argument)
            }
            index += 1
        }
    }

    var verbose: Bool { flags.contains("--verbose") || flags.contains("-v") }
    var fake: Bool { flags.contains("--fake") }
    var wantsHelp: Bool { flags.contains("--help") || flags.contains("-h") || command == "help" }

    func seconds(_ name: String, default value: Double) throws -> Double {
        guard let text = options[name] else { return value }
        guard let number = Double(text), number > 0 else { throw CLIError("\(name) must be a positive number") }
        return number
    }
}

let usage = """
    paperboy-cli — send articles to the Xteink reader over Bluetooth LE

    USAGE
      paperboy-cli scan [--seconds N]
          List readers advertising the Paperboy service (default 8 s).
      paperboy-cli list
          Connect, print the device's status and the articles on it.
      paperboy-cli sync <directory>
          Send every .epub in the directory as it is, and every .html/.htm after cleaning
          and packaging it. Articles already on the device are skipped.
      paperboy-cli push <file> [--title T] [--source S] [--author A] [--url U]
          Send one .epub or .html file. The article id is derived from --url if given.
      paperboy-cli delete <id>
          Delete one article (16 hex digits, as printed by `list`).
      paperboy-cli demo
          Build the three demo articles and sync them.
      paperboy-cli make-epub <directory>
          Write the demo articles as .epub files. No Bluetooth involved.

    OPTIONS
      --verbose, -v     Log every frame and every Bluetooth event to stderr.
      --device UUID     Connect to this reader (identifier as printed by `scan`) instead of
                        the first one found.
      --timeout N       Seconds to wait for the reader to appear and connect (default 30).
      --fake            Talk to an in-memory fake device instead of Bluetooth. With --mtu N
                        it pretends the link has that ATT MTU (default 185).

    The first Bluetooth use asks for permission for your terminal application
    (System Settings › Privacy & Security › Bluetooth).
    """

func stderrLine(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

func timestamped(_ text: String) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return "\(formatter.string(from: Date())) \(text)"
}

let verboseLog: SyncLogger = { stderrLine(timestamped($0)) }

@main
struct PaperboyCLI {
    static func main() async {
        do {
            let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
            if arguments.wantsHelp || arguments.command.isEmpty {
                print(usage)
                exit(arguments.command.isEmpty && !arguments.wantsHelp ? 64 : 0)
            }
            let ok = try await run(arguments)
            exit(ok ? 0 : 1)
        } catch {
            stderrLine("error: \(error)")
            exit(1)
        }
    }

    static func run(_ arguments: Arguments) async throws -> Bool {
        switch arguments.command {
        case "scan":
            try await scan(arguments)
            return true
        case "make-epub":
            guard let directory = arguments.positional.first else { throw CLIError("make-epub needs a directory") }
            try makeEpubs(in: URL(fileURLWithPath: directory))
            return true
        case "demo":
            let items = try DemoArticles.articles.map { (item: $0.syncItem, data: try EpubBuilder.build($0)) }
            return try await sync(StaticSyncSource(items: items), titles: titles(of: items), arguments)
        case "sync":
            guard let directory = arguments.positional.first else { throw CLIError("sync needs a directory") }
            let items = try loadDirectory(URL(fileURLWithPath: directory))
            guard !items.isEmpty else { throw CLIError("no .epub or .html files in \(directory)") }
            return try await sync(StaticSyncSource(items: items), titles: titles(of: items), arguments)
        case "push":
            guard let file = arguments.positional.first else { throw CLIError("push needs a file") }
            let item = try loadFile(URL(fileURLWithPath: file), overrides: arguments.options)
            return try await sync(StaticSyncSource(items: [item]), titles: titles(of: [item]), arguments)
        case "list":
            return try await sync(StaticSyncSource(), titles: [:], arguments, listing: true)
        case "delete":
            guard let text = arguments.positional.first, let id = ArticleID(hex: text) else {
                throw CLIError("delete needs an article id of 16 hex digits")
            }
            return try await sync(StaticSyncSource(deletes: [id]), titles: [:], arguments)
        default:
            throw CLIError("unknown command \"\(arguments.command)\"; try --help")
        }
    }

    static func titles(of items: [(item: SyncItem, data: Data)]) -> [ArticleID: String] {
        var titles: [ArticleID: String] = [:]
        for entry in items { titles[entry.item.id] = entry.item.title }
        return titles
    }

    // MARK: Files

    static func makeEpubs(in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for article in DemoArticles.articles {
            let data = try EpubBuilder.build(article)
            let file = directory.appendingPathComponent("\(article.id.hex).epub")
            try data.write(to: file, options: .atomic)
            print("\(file.path)  \(data.count) bytes  crc32 \(String(format: "%08x", CRC32.checksum(data)))  \"\(article.title)\"")
        }
    }

    static func loadDirectory(_ directory: URL) throws -> [(item: SyncItem, data: Data)] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { ["epub", "html", "htm"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var items: [(item: SyncItem, data: Data)] = []
        var seen = Set<ArticleID>()
        for file in files {
            do {
                let item = try loadFile(file, overrides: [:])
                if seen.insert(item.item.id).inserted {
                    items.append(item)
                } else {
                    stderrLine("skipping \(file.lastPathComponent): same article id as an earlier file")
                }
            } catch {
                stderrLine("skipping \(file.lastPathComponent): \(error)")
            }
        }
        return items
    }

    /// An .epub is sent as it is; an .html file is cleaned and packaged first.
    static func loadFile(_ file: URL, overrides: [String: String]) throws -> (item: SyncItem, data: Data) {
        let raw = try Data(contentsOf: file)
        let modified = ((try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate) ?? Date()
        let baseName = file.deletingPathExtension().lastPathComponent
        let fallbackURL = "file:\(file.lastPathComponent)"

        if file.pathExtension.lowercased() == "epub" {
            let metadata = (try? EpubInspector.metadata(of: raw)) ?? EpubMetadata()
            // EPUBs built by Paperboy carry the canonical URL as their identifier, so the id
            // comes out the same as on the phone.
            let url = overrides["--url"] ?? metadata.identifier ?? fallbackURL
            let item = SyncItem(
                id: ArticleID(canonicalURL: url),
                time: metadata.date ?? modified,
                source: overrides["--source"] ?? metadata.publisher ?? "Mac",
                title: overrides["--title"] ?? metadata.title ?? baseName,
                author: overrides["--author"] ?? metadata.author ?? "")
            return (item, raw)
        }

        let html = String(decoding: raw, as: UTF8.self)
        let article = Article(
            url: overrides["--url"].map(URLCanonicalizer.canonicalize) ?? fallbackURL,
            source: overrides["--source"] ?? "Mac",
            title: overrides["--title"] ?? htmlTitle(html) ?? baseName,
            author: overrides["--author"] ?? "",
            date: modified,
            bodyXHTML: HTMLCleaner.clean(html))
        return (article.syncItem, try EpubBuilder.build(article))
    }

    static func htmlTitle(_ html: String) -> String? {
        guard let open = html.range(of: "<title", options: .caseInsensitive),
              let start = html[open.upperBound...].firstIndex(of: ">"),
              let close = html[start...].range(of: "</title", options: .caseInsensitive)
        else { return nil }
        let title = HTMLCleaner.plainText(String(html[html.index(after: start)..<close.lowerBound]))
        return title.isEmpty ? nil : title
    }

    // MARK: Bluetooth

    static func scan(_ arguments: Arguments) async throws {
        let seconds = try arguments.seconds("--seconds", default: 8)
        let central = BLECentral(options: .init(log: arguments.verbose ? verboseLog : nil))
        try await central.waitUntilPoweredOn(timeout: .seconds(1200))
        print("Scanning for \(SyncProtocol.serviceUUID) for \(Int(seconds)) s…")
        central.startScan()
        let listener = Task<Int, Never> {
            var seen = Set<UUID>()
            for await event in central.events {
                if case .discovered(let identifier, let name, let rssi) = event, seen.insert(identifier).inserted {
                    print("\(identifier.uuidString)  rssi \(rssi)  \(name ?? "(no name)")")
                }
            }
            return seen.count
        }
        try await Task.sleep(for: .seconds(seconds))
        central.stopScan()
        listener.cancel()
        let count = await listener.value
        print(count == 0 ? "No readers found. Is the device on its Home or Articles screen?" : "\(count) reader(s) found.")
    }

    /// Connect (or use the fake device), run one session with `source`, print the outcome.
    static func sync(_ source: StaticSyncSource, titles: [ArticleID: String], _ arguments: Arguments, listing: Bool = false) async throws -> Bool {
        let verbose = arguments.verbose
        let log: SyncLogger? = verbose ? verboseLog : nil
        let transport: any SyncTransport
        var central: BLECentral?

        if arguments.fake {
            let mtu = Int(try arguments.seconds("--mtu", default: 185))
            let device = FakeDevice()
            transport = FakeDeviceTransport(device: device, attMTU: max(23, mtu))
            print("Using the in-memory fake device (ATT MTU \(max(23, mtu))).")
        } else {
            let timeout = try arguments.seconds("--timeout", default: 30)
            let ble = BLECentral(options: .init(log: log))
            central = ble
            try await ble.waitUntilPoweredOn(timeout: .seconds(1200))
            if let text = arguments.options["--device"] {
                guard let identifier = UUID(uuidString: text) else { throw CLIError("--device needs a UUID as printed by `scan`") }
                ble.connect(to: identifier)
            } else {
                ble.connectToFirstReader()
            }
            print("Waiting for the reader (up to \(Int(timeout)) s)…")
            try await ble.waitUntilReady(timeout: .seconds(timeout))
            print("Connected.")
            transport = ble
        }

        let started = Date()
        let report = await SyncSession(transport: transport, source: source, log: log).run()
        let elapsed = Date().timeIntervalSince(started)
        central?.disconnect(forget: true)

        if let device = report.device {
            print("Device: firmware \(device.firmwareVersion), protocol \(device.version), battery \(device.batteryPercent)%, \(device.freeSpaceMB == UInt32.max ? "free space not measured yet" : "\(device.freeSpaceMB) MB free")")
        }
        if listing || verbose {
            print("On the device before this session: \(report.listing.count) article(s)")
            for item in report.listing {
                print("  \(item.id.hex)  \(item.isRead ? "read  " : "unread")  \(titles[item.id] ?? "")")
            }
        }
        for id in report.uploaded { print("sent     \(id.hex)  \(titles[id] ?? "")") }
        for id in report.alreadyPresent { print("present  \(id.hex)  \(titles[id] ?? "")") }
        for id in report.deleted { print("deleted  \(id.hex)") }
        for failure in report.failures { print("FAILED   \(failure.id.hex)  \(failure.reason)  \(titles[failure.id] ?? "")") }
        if report.bytesSent > 0 {
            let rate = elapsed > 0 ? Double(report.bytesSent) / elapsed / 1024 : 0
            print(String(format: "%d bytes in %.1f s (%.1f kB/s)", report.bytesSent, elapsed, rate))
        }
        if report.deviceFull { print("The device is full; some articles were not sent.") }
        if let error = report.error {
            print("Session stopped early: \(error)")
            return false
        }
        print("Session complete.")
        return report.failures.isEmpty
    }
}
