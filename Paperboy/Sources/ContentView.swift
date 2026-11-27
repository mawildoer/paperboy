import PaperboyCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var coordinator: SyncCoordinator
    @EnvironmentObject private var bluetooth: BluetoothTransport
    @State private var loginService: LoginService?
    @State private var showingSettings = false
    @State private var showingLog = false
    @State private var filter: ArticleFilter = .all
    @State private var searchText = ""
    @State private var sort: ArticleSort = .newest

    var body: some View {
        NavigationStack {
            List {
                if let error = coordinator.startupError {
                    Section { Text(error).foregroundStyle(.red) }
                }
                if coordinator.importActivity != nil || coordinator.importError != nil {
                    Section("Import") {
                        if let activity = coordinator.importActivity { ProgressView(activity) }
                        if let error = coordinator.importError { Text(error).foregroundStyle(.red) }
                    }
                }
                if let activity = coordinator.firmwareActivity { Section("Firmware") { Text(activity) } }
                if let error = coordinator.firmwareError { Section("Firmware") { Text(error).foregroundStyle(.red) } }
                if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    readerSection
                    sourcesSection
                }
                articlesSection
            }
            .navigationTitle("Paperboy")
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Title, author, or source")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button { showingLog = true } label: { Label("Log", systemImage: "doc.plaintext") }
                }
            }
            .refreshable {
                await coordinator.fetch(reason: "pull to refresh", includeWebSources: true, limitSeconds: 600)
            }
        }
        .sheet(item: $loginService) { service in
            LoginSheet(service: service, extraHosts: service == .substack ? coordinator.settings.substackPublications : []) { _ in
                coordinator.loginFinished(service)
            }
        }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .sheet(isPresented: $showingLog) { LogView() }
    }

    // MARK: Reader

    private var linkText: String {
        switch bluetooth.state {
        case .starting: return "Starting Bluetooth…"
        case .unavailable(let why): return why
        case .searching: return "Looking for a reader…"
        case .waiting: return "Waiting for the reader to wake"
        case .connected(let name): return "Connected to \(name)"
        }
    }

    private var readerSection: some View {
        Section("Reader") {
            HStack {
                Image(systemName: isConnected ? "dot.radiowaves.left.and.right" : "moon.zzz")
                    .foregroundStyle(isConnected ? .green : .secondary)
                Text(linkText)
            }
            LabeledContent("Last sync", value: coordinator.device.lastSync.map(Self.relative) ?? "never")
            if let result = coordinator.device.lastResult {
                LabeledContent("Result", value: result)
            }
            if let battery = coordinator.device.batteryPercent {
                LabeledContent("Battery", value: "\(battery)%")
            }
            if let free = coordinator.device.freeSpaceMB {
                LabeledContent("Free space", value: free >= 1024 ? String(format: "%.1f GB", Double(free) / 1024) : "\(free) MB")
            }
            LabeledContent("Firmware") {
                HStack {
                    Text(coordinator.device.firmware ?? "Unknown")
                    Button("Update") { coordinator.updateFirmware() }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Update reader firmware")
                        .disabled(!isConnected || coordinator.firmwareUpdating)
                }
            }
            Button {
                coordinator.syncNow()
            } label: {
                HStack {
                    Text("Sync now")
                    Spacer()
                    if let activity = coordinator.activity {
                        Text(activity).font(.footnote).foregroundStyle(.secondary)
                        ProgressView()
                    }
                }
            }
            .disabled(coordinator.activity != nil || coordinator.firmwareUpdating)
        }
    }

    private var isConnected: Bool {
        if case .connected = bluetooth.state { return true }
        return false
    }

    // MARK: Sources

    private var sourcesSection: some View {
        Section {
            ForEach(LoginService.allCases) { service in
                HStack {
                    VStack(alignment: .leading) {
                        Text(service.displayName)
                        Text(coordinator.signedIn[service] == true ? "Signed in" : "Not signed in")
                            .font(.footnote)
                            .foregroundStyle(coordinator.signedIn[service] == true ? .green : .secondary)
                    }
                    Spacer()
                    Button(coordinator.signedIn[service] == true ? "Open" : "Sign in") { loginService = service }
                        .buttonStyle(.borderless)
                }
            }
        } header: {
            Text("Sources")
        } footer: {
            if let fetched = coordinator.lastFetch {
                Text("Last fetch \(Self.relative(fetched))." + (coordinator.lastFetchNote.map { " \($0)" } ?? ""))
            }
        }
    }

    // MARK: Articles

    private enum ArticleFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case unread = "Unread"
        case reader = "On reader"
        var id: String { rawValue }
    }

    private enum ArticleSort: String, CaseIterable, Identifiable {
        case newest = "Newest first"
        case oldest = "Oldest first"
        case source = "By source"
        var id: String { rawValue }
    }

    private var shownArticles: [StoredArticle] {
        var filtered: [StoredArticle]
        switch filter {
        case .all: filtered = coordinator.articles
        case .unread: filtered = coordinator.articles.filter { !$0.read }
        case .reader: filtered = coordinator.articles.filter { $0.load != .off || $0.onDevice }
        }
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return filtered.enumerated().compactMap { index, article -> (StoredArticle, Int, Int)? in
                guard let score = MetadataSearch.score(searchText, title: article.title, author: article.author, source: article.source) else { return nil }
                return (article, score, index)
            }.sorted { $0.1 == $1.1 ? $0.2 < $1.2 : $0.1 > $1.1 }.map { $0.0 }
        }
        // The store hands them over newest first.
        switch sort {
        case .newest: return filtered
        case .oldest: return filtered.reversed()
        case .source:
            return filtered.sorted { ($0.source.lowercased(), $1.date) < ($1.source.lowercased(), $0.date) }
        }
    }

    private var articlesSection: some View {
        let visible = shownArticles
        return Section {
            Picker("Show", selection: $filter) {
                ForEach(ArticleFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if visible.isEmpty {
                if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    Text(coordinator.articles.isEmpty ? "Nothing fetched yet." : "Nothing here.").foregroundStyle(.secondary)
                }
            }
            ForEach(visible) { article in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(article.title)
                            .font(.body)
                            .fontWeight(article.read ? .regular : .semibold)
                            .foregroundStyle(article.read ? .secondary : .primary)
                            .lineLimit(2)
                        Text(Self.subtitle(article))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if !article.preview.isEmpty {
                            Text(article.preview)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                    Spacer(minLength: 0)
                    VStack(spacing: 12) {
                        loadButton(article)
                        Button { coordinator.bump(article.id) } label: {
                            VStack(spacing: 2) {
                                Image(systemName: "arrow.up.to.line.circle").font(.title2)
                                Text(article.pendingBump == nil ? "Bump" : "Bump queued").font(.caption2)
                            }.frame(width: 64)
                        }
                        .buttonStyle(.plain)
                        .disabled(!article.wantedOnDevice || coordinator.firmwareUpdating)
                        .accessibilityLabel("Bump \(article.title) to the top of Touched on the reader")
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            HStack {
                Text("Articles (\(visible.count))")
                Spacer()
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(ArticleSort.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    Label(sort.rawValue, systemImage: "arrow.up.arrow.down")
                        .font(.footnote)
                        .textCase(nil)
                }
            }
        } footer: {
            Text("Bump moves a loaded article to the top of Touched on the reader at the next sync. Search matches title, author, and source. Tap Load to put an article on the reader, again to lock it there, again to take it off. A loaded article leaves the reader once you have read it; a locked one stays.")
        }
    }

    /// Off, load, lock: one tap steps to the next. The caption says where the reader stands.
    private func loadButton(_ article: StoredArticle) -> some View {
        let look = Self.loadLook(article)
        return Button {
            coordinator.setLoad(article.id, article.load.next)
        } label: {
            VStack(spacing: 2) {
                Image(systemName: look.symbol)
                    .font(.title2)
                    .foregroundStyle(look.color)
                Text(look.caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 64)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(look.caption). Tap to change.")
    }

    private static func loadLook(_ article: StoredArticle) -> (symbol: String, color: Color, caption: String) {
        switch article.load {
        case .off:
            return article.onDevice
                ? ("arrow.down.circle", .secondary, "Removing")
                : ("arrow.down.circle", .secondary, "Load")
        case .load:
            return article.onDevice
                ? ("checkmark.circle.fill", .blue, "On reader")
                : ("arrow.down.circle.fill", .blue, "Queued")
        case .lock:
            return article.onDevice
                ? ("lock.circle.fill", .orange, "Locked")
                : ("lock.circle.fill", .orange, "Queued")
        }
    }

    private static func subtitle(_ article: StoredArticle) -> String {
        // The date goes first so it is never the part that gets cut off.
        var parts = [dateText(article.date), article.source]
        if !article.author.isEmpty, article.author != article.source { parts.append(article.author) }
        if article.read { parts.append("read") }
        return parts.joined(separator: " · ")
    }

    /// "Today", "Yesterday", "Mon 16 Nov", and the year once it is not this one.
    private static func dateText(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: Date())
        return date.formatted(sameYear
            ? .dateTime.weekday(.abbreviated).day().month(.abbreviated)
            : .dateTime.day().month(.abbreviated).year())
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct LogView: View {
    @EnvironmentObject private var log: AppLog
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(log.lines.isEmpty ? "Nothing logged yet." : log.lines.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding()
            }
            .navigationTitle("Log")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
