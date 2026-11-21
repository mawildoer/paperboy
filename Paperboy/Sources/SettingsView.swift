import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var coordinator: SyncCoordinator
    @EnvironmentObject private var bluetooth: BluetoothTransport
    @Environment(\.dismiss) private var dismiss
    @State private var newPublication = ""
    @State private var newFeed = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Fetch Substack", isOn: $coordinator.settings.substackEnabled)
                    Toggle("Use my Substack inbox", isOn: $coordinator.settings.substackUseInbox)
                    Stepper("Up to \(coordinator.settings.substackMaxPerFetch) posts per fetch", value: $coordinator.settings.substackMaxPerFetch, in: 1...50)
                } header: {
                    Text("Substack")
                } footer: {
                    Text("The inbox covers everything you subscribe to, up to the limit above.")
                }

                Section {
                    ForEach(coordinator.settings.substackPublications, id: \.self) { host in
                        Text(host)
                    }
                    .onDelete { coordinator.settings.substackPublications.remove(atOffsets: $0) }
                    addRow("slowboring.com or name.substack.com", text: $newPublication) {
                        let host = Self.hostOnly(newPublication)
                        if !host.isEmpty, !coordinator.settings.substackPublications.contains(host) {
                            coordinator.settings.substackPublications.append(host)
                        }
                        newPublication = ""
                    }
                    Toggle("Load their new posts onto the reader", isOn: $coordinator.settings.autoLoadFavourites)
                } header: {
                    Text("Favourite authors")
                } footer: {
                    Text("Every new post from these is fetched first, whatever the limit. Paid posts need your Substack sign-in to include a paid subscription to them.")
                }

                Section {
                    Toggle("Fetch The New York Times", isOn: $coordinator.settings.nytEnabled)
                    Stepper("Up to \(coordinator.settings.nytDailyCap) articles a day", value: $coordinator.settings.nytDailyCap, in: 1...100)
                    ForEach(coordinator.settings.nytFeeds, id: \.self) { feed in
                        Text(feed).font(.footnote)
                    }
                    .onDelete { coordinator.settings.nytFeeds.remove(atOffsets: $0) }
                    addRow("https://rss.nytimes.com/…/World.xml", text: $newFeed) {
                        let feed = newFeed.trimmingCharacters(in: .whitespaces)
                        if URL(string: feed)?.host != nil, !coordinator.settings.nytFeeds.contains(feed) {
                            coordinator.settings.nytFeeds.append(feed)
                        }
                        newFeed = ""
                    }
                } header: {
                    Text("The New York Times")
                } footer: {
                    Text("RSS feeds from rss.nytimes.com, or section page addresses.")
                }

                Section {
                    Stepper("Keep unread for \(Int(coordinator.settings.unreadDays)) days", value: $coordinator.settings.unreadDays, in: 1...60, step: 1)
                    Stepper("Keep read for \(Int(coordinator.settings.readDays)) days", value: $coordinator.settings.readDays, in: 1...30, step: 1)
                } header: {
                    Text("Retention")
                } footer: {
                    Text("After that an article is removed from the reader at the next sync.")
                }

                Section {
                    Stepper(
                        "Fetch for up to \(Int(coordinator.settings.connectFetchSeconds)) s when the reader connects",
                        value: $coordinator.settings.connectFetchSeconds, in: 0...30, step: 1)
                    Button("Forget this reader", role: .destructive) { bluetooth.forgetReader() }
                        .disabled(bluetooth.knownReader == nil)
                    ForEach(LoginService.allCases) { service in
                        Button("Sign out of \(service.displayName)", role: .destructive) { coordinator.signOut(service) }
                            .disabled(coordinator.signedIn[service] != true)
                    }
                } header: {
                    Text("Reader and accounts")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func addRow(_ prompt: String, text: Binding<String>, add: @escaping () -> Void) -> some View {
        HStack {
            TextField(prompt, text: text)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .onSubmit(add)
            Button("Add", action: add)
                .buttonStyle(.borderless)
                .disabled(text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    /// "https://Example.substack.com/p/x" → "example.substack.com"
    private static func hostOnly(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        if let host = URLComponents(string: trimmed)?.host { return host }
        if let host = URLComponents(string: "https://" + trimmed)?.host { return host }
        return ""
    }
}
