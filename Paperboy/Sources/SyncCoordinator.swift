import Foundation
import PaperboyCore

#if os(iOS)
import BackgroundTasks
import UIKit
#endif

/// Ties everything together: fetches articles, and runs a sync session whenever the reader
/// connects. Owns the state the UI shows.
@MainActor
final class SyncCoordinator: ObservableObject {
    struct DeviceStatus: Equatable {
        var lastSync: Date?
        var batteryPercent: Int?
        var freeSpaceMB: Int?
        var firmware: String?
        var lastResult: String?
    }

    static let refreshTaskIdentifier = "local.paperboy.refresh"
    static let processingTaskIdentifier = "local.paperboy.processing"
    private static let statusKey = "paperboy.deviceStatus.v1"

    @Published var settings: AppSettings {
        didSet { if settings != oldValue { settings.save() } }
    }
    @Published private(set) var articles: [StoredArticle] = []
    @Published private(set) var device = DeviceStatus()
    @Published private(set) var firmwareUpdating = false
    @Published private(set) var firmwareActivity: String?
    @Published private(set) var firmwareError: String?
    @Published private(set) var activity: String?
    @Published private(set) var lastFetch: Date?
    @Published private(set) var lastFetchNote: String?
    @Published private(set) var signedIn: [LoginService: Bool] = [:]
    @Published private(set) var startupError: String?
    @Published private(set) var importError: String?
    @Published private(set) var importActivity: String?

    let bluetooth = BluetoothTransport()
    private let substack = SubstackSource()
    private let nyt = NYTSource()
    private let medium = MediumSource()
    private var store: ArticleStore?
    private var fetchTask: Task<FetchSummary, Never>?
    private var syncTask: Task<Void, Never>?
    private var validationAttempted = false
    private var firmwareTask: Task<Void, Never>?
    private var pendingFirmwareVersion: String?
    private var pendingFirmwarePrevious: String?
    private var firmwareTimeout: Task<Void, Never>?
    private var loadChangeSync: Task<Void, Never>?

    private init() {
        settings = AppSettings.load()
        loadDeviceStatus()
        do {
            let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            store = try ArticleStore(directory: base.appendingPathComponent("Articles", isDirectory: true))
        } catch {
            startupError = "Could not open the article library: \(error.localizedDescription)"
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--paperboy-firmware-validation") {
            firmwareActivity = "Waiting to validate Bluetooth firmware update…"
        }
        #endif
        bluetooth.onReady = { [weak self] in self?.readerConnected() }
    }

    /// One instance for the whole process. It is created at launch, not when the first view
    /// appears: when iOS relaunches the app in the background for a Bluetooth event there may
    /// be no view at all, and the central manager must exist to receive the restored state.
    static let shared = SyncCoordinator()

    /// The UI came to the front.
    func appOpened() {
        bluetooth.start()
        Task {
            #if targetEnvironment(simulator)
            // The simulator has no sign-ins and no Bluetooth: show the demo articles so the list
            // can be looked at.
            for article in DemoArticles.articles { _ = try? await store?.add(article) }
            #endif
            try? await store?.backfillPreviews()
            await processSharedInbox()
            await refreshArticles()
            await refreshLoginStatus()
            // "A fetch also runs … on app open."
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--paperboy-firmware-validation") { return }
            #endif
            _ = await fetch(reason: "app open", includeWebSources: true, limitSeconds: 600)
        }
    }

    // MARK: State for the UI

    func refreshArticles() async {
        guard let store else { return }
        articles = await store.all()
    }

    // MARK: Pages shared from the share sheet

    static let appGroup = "group.app.paperboy.readerc67aad"
    private var processingShared = false
    private var rescanShared = false

    /// Files/Open In supplies security-scoped URLs; copy before releasing access.
    func importDocument(_ url: URL) {
        Task {
            guard url.isFileURL,
                  let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup) else { return }
            do {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                _ = try await Task.detached(priority: .userInitiated) {
                    try PDFInbox.queueFile(at: url, container: container, title: url.deletingPathExtension().lastPathComponent)
                }.value
                importError = nil
                await processSharedInbox()
                if case .connected = bluetooth.state { readerConnected() }
            } catch { importError = error.localizedDescription }
        }
    }

    private func removeQueued(_ page: SharedPage, record: URL, container: URL) {
        try? FileManager.default.removeItem(at: record)
        if let filename = page.pdfFile, let pdf = try? PDFInbox.fileURL(named: filename, container: container) {
            try? FileManager.default.removeItem(at: pdf)
        }
    }

    /// Turn every page the share extension left in the app group's Inbox into an article, loaded
    /// for the reader. A page that cannot be read is tried again on later runs, three times in all.
    func processSharedInbox() async {
        if processingShared { rescanShared = true; return }
        guard let store,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup)
        else { return }
        processingShared = true
        defer {
            processingShared = false
            importActivity = nil
            if rescanShared {
                rescanShared = false
                Task { await processSharedInbox() }
            }
        }
        let inbox = container.appendingPathComponent("Inbox", isDirectory: true)
        let files = ((try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
        guard !files.isEmpty else { return }
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  var page = try? JSONDecoder().decode(SharedPage.self, from: data) else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            let canonical = URLCanonicalizer.canonicalize(page.url)
            let id = ArticleID(canonicalURL: canonical)
            if let known = await store.article(id), !known.isRetired {
                // Shared again: put it (back) on the reader, and keep it there if it was read.
                try? await store.setLoad(id, known.read ? .lock : .load)
                removeQueued(page, record: file, container: container)
                AppLog.post("Shared: \(known.title) is already in the list; loading it")
                continue
            }
            do {
                importActivity = page.pdfFile == nil ? "Importing shared page…" : "Converting PDF on this device…"
                var article = try await article(forShared: page)
                article.url = canonical
                article = await ArticleImagePipeline.prepare(article)
                try? await store.remove(id)  // a retired entry would block the add
                try await store.add(article, load: .load)
                removeQueued(page, record: file, container: container)
                importError = nil
                AppLog.post("Shared: stored \(article.title) [\(article.source)]")
            } catch {
                page.attempts += 1
                importError = "Could not import \(page.title ?? "shared document"): \(error.localizedDescription)"
                AppLog.post("Shared: \(URL(string: page.url)?.host ?? "page") could not be read (try \(page.attempts) of 3): \(error)")
                if page.attempts >= 3 {
                    removeQueued(page, record: file, container: container)
                } else if let updated = try? JSONEncoder().encode(page) {
                    try? updated.write(to: file, options: .atomic)
                }
            }
        }
        await refreshArticles()
    }

    /// The page as shared when it carries the article; otherwise fetched the way its site needs.
    private func article(forShared page: SharedPage) async throws -> Article {
        if let filename = page.pdfFile {
            guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup) else { throw CocoaError(.fileReadUnknown) }
            let file = try PDFInbox.fileURL(named: filename, container: container)
            return try await Task.detached(priority: .userInitiated) {
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= PDFInbox.maxBytes else { throw PDFInbox.Failure.tooLarge }
                return try PDFImporter.article(data: Data(contentsOf: file, options: .mappedIfSafe), url: page.url, title: page.title, now: page.sharedAt)
            }.value
        }
        if let html = page.html,
           let article = try? await ReaderModeExtractor().article(html: html, url: page.url, title: page.title) {
            return article
        }
        guard let url = URL(string: page.url), let host = url.host?.lowercased() else { throw URLError(.badURL) }
        if MediumDiscovery.isMediumHost(host) {
            return try await medium.fetchArticle(page.url)
        }
        if host.hasSuffix("nytimes.com") {
            return try await nyt.fetchArticle(page.url)
        }
        if url.path.contains("/p/"), let article = try? await substack.fetchPost(canonicalURL: page.url) {
            return article
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        var data = Data()
        var isPDF = response.mimeType?.lowercased() == "application/pdf" || url.pathExtension.lowercased() == "pdf"
        for try await byte in bytes {
            if data.count >= (isPDF ? PDFInbox.maxBytes : 4_000_000) { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
            if data.count == 1024 && PDFInbox.hasPDFHeader(data) { isPDF = true }
        }
        if isPDF || PDFInbox.hasPDFHeader(data) {
            let pdf = data
            return try await Task.detached(priority: .userInitiated) {
                try PDFImporter.article(data: pdf, url: page.url, title: page.title, now: page.sharedAt)
            }.value
        }
        return try await ReaderModeExtractor().article(html: String(decoding: data, as: UTF8.self), url: page.url, title: page.title)
    }

    /// The load / lock / off control of one article. The reader follows at the next sync; when it
    /// is connected right now, that sync starts a moment after the last tap.
    func setLoad(_ id: ArticleID, _ state: LoadState) {
        guard let store else { return }
        Task {
            try? await store.setLoad(id, state)
            await refreshArticles()
            loadChangeSync?.cancel()
            loadChangeSync = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self, self.syncTask == nil,
                      case .connected = self.bluetooth.state else { return }
                self.syncTask = Task { [weak self] in
                    await self?.runSession()
                    self?.syncTask = nil
                }
            }
        }
    }

    func refreshLoginStatus() async {
        for service in LoginService.allCases {
            let hosts = service == .substack ? settings.substackPublications : []
            await WebSession.logCookieState(service, when: "before copy")
            // Copying on every refresh keeps URLSession's cookies as fresh as the web view's.
            await WebSession.copyCookies(for: service, alsoHosts: hosts)
            signedIn[service] = await WebSession.isSignedIn(service)
        }
    }

    func loginFinished(_ service: LoginService) {
        if service == .nyt { nyt.resetBotCheck() }
        Task {
            await refreshLoginStatus()
            _ = await fetch(reason: "signed in", includeWebSources: true, limitSeconds: 600)
        }
    }

    func signOut(_ service: LoginService) {
        Task {
            await WebSession.signOut(service)
            await refreshLoginStatus()
        }
    }

    private func loadDeviceStatus() {
        let defaults = UserDefaults.standard
        guard let saved = defaults.dictionary(forKey: Self.statusKey) else { return }
        device.lastSync = (saved["lastSync"] as? Double).map(Date.init(timeIntervalSince1970:))
        device.batteryPercent = saved["battery"] as? Int
        device.freeSpaceMB = saved["free"] as? Int
        device.firmware = saved["firmware"] as? String
        device.lastResult = saved["result"] as? String
    }

    private func saveDeviceStatus() {
        var saved: [String: Any] = [:]
        if let lastSync = device.lastSync { saved["lastSync"] = lastSync.timeIntervalSince1970 }
        if let battery = device.batteryPercent { saved["battery"] = battery }
        if let free = device.freeSpaceMB { saved["free"] = free }
        if let firmware = device.firmware { saved["firmware"] = firmware }
        if let result = device.lastResult { saved["result"] = result }
        UserDefaults.standard.set(saved, forKey: Self.statusKey)
    }

    // MARK: Fetching

    /// Fetch new articles from the enabled sources. Runs are not stacked: a second call while
    /// one is running waits for that one.
    @discardableResult
    func fetch(reason: String, includeWebSources: Bool, limitSeconds: Double) async -> FetchSummary {
        if firmwareTask != nil || pendingFirmwareVersion != nil { return FetchSummary() }
        if let running = fetchTask { return await running.value }
        guard let store else { return FetchSummary() }
        let settings = self.settings
        let deadline = Date().addingTimeInterval(limitSeconds)
        let substack = self.substack
        let nyt = self.nyt
        let medium = self.medium
        AppLog.shared.add("Fetch (\(reason)) started")
        if activity == nil { activity = "Fetching articles…" }

        let task = Task { @MainActor () -> FetchSummary in
            var summary = FetchSummary()
            if settings.substackEnabled {
                summary.merge(await substack.fetchNew(settings: settings, store: store, deadline: deadline))
            }
            if settings.mediumEnabled, includeWebSources, !Task.isCancelled, Date() < deadline {
                summary.merge(await medium.fetchNew(settings: settings, store: store, deadline: deadline))
            }
            if settings.nytEnabled, includeWebSources, !Task.isCancelled, Date() < deadline {
                summary.merge(await nyt.fetchNew(settings: settings, store: store, deadline: deadline))
            }
            return summary
        }
        fetchTask = task
        let summary = await task.value
        fetchTask = nil

        for note in summary.notes { AppLog.shared.add(note) }
        AppLog.shared.add("Fetch finished: \(summary.added) new, \(summary.failed) failed")
        lastFetch = Date()
        lastFetchNote = summary.notes.last
        if activity == "Fetching articles…" { activity = nil }
        await refreshArticles()
        return summary
    }

    private func cancelFetch() {
        fetchTask?.cancel()
    }

    // MARK: Syncing

    /// The reader just connected: a short fetch of anything new, then the session.
    private func readerConnected() {
        if pendingFirmwareVersion != nil {
            verifyFirmwareAfterReboot()
            return
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--paperboy-firmware-validation"), firmwareTask == nil, !validationAttempted,
           !UserDefaults.standard.bool(forKey: "paperboy.firmwareValidation.completed") {
            validationAttempted = true
            updateFirmware(validation: true)
            return
        }
        #endif
        guard firmwareTask == nil else { return }
        guard syncTask == nil else { return }
        syncTask = Task { [weak self] in
            await self?.fetchThenSync()
            self?.syncTask = nil
        }
    }

    /// "Sync now": if the reader is connected, sync; either way fetch first.
    func syncNow() {
        if case .connected = bluetooth.state {
            readerConnected()
        } else {
            bluetooth.start()
            Task { _ = await fetch(reason: "sync now", includeWebSources: true, limitSeconds: 600) }
        }
    }

    private func fetchThenSync() async {
        #if os(iOS)
        // Ask for time to finish if the app is (or goes) in the background.
        let assertion = UIApplication.shared.beginBackgroundTask(withName: "paperboy.sync")
        defer { if assertion != .invalid { UIApplication.shared.endBackgroundTask(assertion) } }
        #endif

        // UNVERIFIED: how long the reader waits for HELLO after connecting. DESIGN.md gives it
        // 8 s to connect and 90 s to finish a transfer before it sleeps, so the fetch here is
        // short (Substack only; rendered pages take seconds each) and is cut off at the limit.
        await processSharedInbox()
        let limit = max(0, settings.connectFetchSeconds)
        if limit > 0 {
            let watchdog = Task { [weak self] in
                try? await Task.sleep(for: .seconds(limit))
                if !Task.isCancelled { self?.cancelFetch() }
            }
            _ = await fetch(reason: "reader connected", includeWebSources: false, limitSeconds: limit)
            watchdog.cancel()
        }
        await runSession()
    }

    private func runSession() async {
        guard let store else { return }
        activity = "Syncing with the reader…"
        defer { activity = nil }
        let source = ArticleStoreSyncSource(store: store, policy: settings.retention)
        let session = SyncSession(transport: bluetooth.transport, source: source, log: { AppLog.post($0) })
        let report = await session.run()

        if let info = report.device {
            device.batteryPercent = Int(info.batteryPercent)
            // 0xFFFFFFFF: the reader has not measured its card yet (DESIGN.md).
            device.freeSpaceMB = info.freeSpaceMB == UInt32.max ? nil : Int(info.freeSpaceMB)
            device.firmware = info.firmwareVersion
        }
        var parts: [String] = []
        if !report.uploaded.isEmpty { parts.append("\(report.uploaded.count) sent") }
        if !report.deleted.isEmpty { parts.append("\(report.deleted.count) removed") }
        if !report.failures.isEmpty { parts.append("\(report.failures.count) failed") }
        if report.deviceFull { parts.append("reader is full") }
        if let error = report.error {
            parts.append("stopped: \(error)")
        } else {
            device.lastSync = Date()
            if parts.isEmpty { parts.append("up to date") }
        }
        device.lastResult = parts.joined(separator: ", ")
        saveDeviceStatus()
        AppLog.shared.add("Sync: \(device.lastResult ?? "")")
        await refreshArticles()
    }

    // MARK: Firmware updates

    func updateFirmware(validation: Bool = false) {
        guard firmwareTask == nil, pendingFirmwareVersion == nil else { return }
        guard case .connected = bluetooth.state else {
            firmwareError = "Connect to the reader in its Library before updating firmware."
            return
        }
        firmwareError = nil
        firmwareUpdating = true
        cancelFetch()
        loadChangeSync?.cancel()
        let oldSync = syncTask
        oldSync?.cancel()
        firmwareTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.firmwareTask = nil
                if self.pendingFirmwareVersion == nil { self.firmwareUpdating = false }
            }
            #if os(iOS)
            let priorIdleTimer = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            defer { UIApplication.shared.isIdleTimerDisabled = priorIdleTimer }
            #endif
            await oldSync?.value
            do {
                self.firmwareActivity = "Downloading firmware…"
                let release: FirmwareRelease
                #if DEBUG
                if validation {
                    let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("paperboy-firmware-validation.bin")
                    let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= FirmwareUpdateSession.maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
                    release = FirmwareRelease(version: "0.2.0-paperboy", image: try Data(contentsOf: file))
                } else { release = try await FirmwareRelease.latest() }
                #else
                release = try await FirmwareRelease.latest()
                #endif
                let transfer = FirmwareUpdateSession(transport: self.bluetooth.transport) { value in
                    Task { @MainActor [weak self] in if self?.pendingFirmwareVersion == nil { self?.firmwareActivity = "Sending firmware: \(Int(value * 100))%" } }
                }
                guard let previous = try await transfer.install(release.image, targetVersion: release.version) else {
                    self.firmwareActivity = "Reader firmware is up to date."
                    return
                }
                self.pendingFirmwareVersion = release.version
                self.pendingFirmwarePrevious = previous
                self.firmwareActivity = "Installing firmware; waiting for the reader to restart…"
                AppLog.post("Firmware install accepted: \(previous) -> \(release.version); waiting for reboot")
                self.firmwareTimeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(120)) } catch { return }
                    guard let self, self.pendingFirmwareVersion != nil else { return }
                    self.pendingFirmwareVersion = nil
                    self.firmwareUpdating = false
                    self.firmwareActivity = nil
                    self.firmwareError = "The reader has not reconnected. Its update is not yet confirmed; leave it powered on in Library."
                }
            } catch {
                self.firmwareActivity = nil
                self.firmwareError = String(describing: error)
                AppLog.post("Firmware update failed: \(error)")
            }
        }
    }

    private func verifyFirmwareAfterReboot() {
        guard firmwareTask == nil, let expected = pendingFirmwareVersion else { return }
        firmwareTask = Task { [weak self] in
            guard let self else { return }
            defer { self.firmwareTask = nil; self.firmwareUpdating = false }
            do {
                let transport = self.bluetooth.transport
                try await transport.send(Frame.hello(version: SyncProtocol.version, unixTime: UInt32(clamping: Int(Date().timeIntervalSince1970))).encode(), withResponse: true)
                let reply = try Frame.decode(try await transport.receive(timeout: .seconds(15)))
                guard case .helloAck(let ack) = reply else { throw SyncError.protocolViolation("missing post-update handshake") }
                self.device.firmware = ack.firmwareVersion
                self.saveDeviceStatus()
                guard ack.firmwareVersion == expected, ack.firmwareVersion != self.pendingFirmwarePrevious else {
                    throw SyncError.transport("reader restarted with \(ack.firmwareVersion); expected \(expected)")
                }
                self.firmwareTimeout?.cancel()
                self.pendingFirmwareVersion = nil
                self.firmwareActivity = "Firmware updated to \(ack.firmwareVersion)."
                AppLog.post("Firmware update verified after reboot: \(ack.firmwareVersion)")
                #if DEBUG
                UserDefaults.standard.set(true, forKey: "paperboy.firmwareValidation.completed")
                #endif
            } catch {
                self.pendingFirmwareVersion = nil
                self.firmwareTimeout?.cancel()
                self.firmwareActivity = nil
                self.firmwareError = String(describing: error)
                AppLog.post("Firmware verification failed: \(error)")
            }
        }
    }

    // MARK: Background refresh

    /// Work for a background task: fetch within the time iOS allows.
    func backgroundFetch(includeWebSources: Bool, limitSeconds: Double) async -> Bool {
        let summary = await fetch(reason: "background", includeWebSources: includeWebSources, limitSeconds: limitSeconds)
        return summary.failed == 0 || summary.added > 0
    }

    func cancelBackgroundWork() {
        cancelFetch()
    }
}

#if os(iOS)
/// BGTask is not Sendable, but it is safe to finish it from any thread.
private struct BackgroundTaskBox: @unchecked Sendable {
    let task: BGTask
}

extension SyncCoordinator {
    /// Must be called before the app finishes launching (from the App's init).
    /// The identifiers must also be listed under BGTaskSchedulerPermittedIdentifiers.
    func registerBackgroundTasks() {
        let scheduler = BGTaskScheduler.shared
        // The handlers are delivered on the main queue (`using: .main`): closures written here
        // are main-actor isolated, and Swift 6 traps if such a closure runs on another queue.
        //
        // UNVERIFIED: the hidden NYT web view working inside either task. App refresh gets about
        // 30 s, so it only does Substack; the processing task (minutes, usually while charging
        // overnight) also tries NYT.
        scheduler.register(forTaskWithIdentifier: Self.refreshTaskIdentifier, using: .main) { task in
            let box = BackgroundTaskBox(task: task)
            Task { @MainActor in
                await SyncCoordinator.shared.runBackgroundTask(box, includeWebSources: false, limitSeconds: 20)
            }
        }
        scheduler.register(forTaskWithIdentifier: Self.processingTaskIdentifier, using: .main) { task in
            let box = BackgroundTaskBox(task: task)
            Task { @MainActor in
                await SyncCoordinator.shared.runBackgroundTask(box, includeWebSources: true, limitSeconds: 240)
            }
        }
    }

    private func runBackgroundTask(_ box: BackgroundTaskBox, includeWebSources: Bool, limitSeconds: Double) async {
        scheduleBackgroundTasks()  // always queue the next one first
        // iOS calls the expiration handler on a queue of its choosing, so it must not be
        // main-actor isolated: hence the explicit @Sendable and the hop.
        box.task.expirationHandler = { @Sendable in
            Task { @MainActor in SyncCoordinator.shared.cancelBackgroundWork() }
        }
        let ok = await backgroundFetch(includeWebSources: includeWebSources, limitSeconds: limitSeconds)
        box.task.setTaskCompleted(success: ok)
    }

    /// Ask iOS for the next runs. iOS decides when (and whether) they happen.
    func scheduleBackgroundTasks() {
        let refresh = BGAppRefreshTaskRequest(identifier: Self.refreshTaskIdentifier)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        let processing = BGProcessingTaskRequest(identifier: Self.processingTaskIdentifier)
        processing.requiresNetworkConnectivity = true
        processing.requiresExternalPower = false
        processing.earliestBeginDate = Date(timeIntervalSinceNow: 2 * 60 * 60)
        for request in [refresh, processing] as [BGTaskRequest] {
            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                AppLog.shared.add("Could not schedule \(request.identifier): \(error.localizedDescription)")
            }
        }
    }
}
#endif
