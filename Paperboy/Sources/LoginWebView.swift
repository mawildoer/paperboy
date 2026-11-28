import PaperboyCore
import SwiftUI
import WebKit

#if canImport(UIKit)
import UIKit
typealias PlatformViewRepresentable = UIViewRepresentable
#else
import AppKit
typealias PlatformViewRepresentable = NSViewRepresentable  // only so the sources typecheck on a Mac
#endif

/// Publisher accounts available in the app.
enum LoginService: String, CaseIterable, Identifiable, Sendable {
    case substack
    case nyt
    case medium
    case economist

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .substack: return "Substack"
        case .economist: return "The Economist"
        case .medium: return "Medium"
        case .nyt: return "The New York Times"
        }
    }

    var loginURL: URL? {
        switch self {
        case .substack: return SubstackEndpoints.signIn
        case .economist: return URL(string: EconomistDiscovery.frontPageURL)
        case .medium: return MediumDiscovery.loginURL
        case .nyt: return NYTDiscovery.loginURL
        }
    }

    /// Cookies whose domain ends with this belong to the service.
    var cookieDomainSuffix: String {
        switch self {
        case .substack: return "substack.com"
        case .economist: return "economist.com"
        case .medium: return "medium.com"
        case .nyt: return "nytimes.com"
        }
    }

    func ownsCookieDomain(_ value: String) -> Bool {
        let domain = value.lowercased().trimmingCharacters(in: ["."])
        return domain == cookieDomainSuffix || domain.hasSuffix("." + cookieDomainSuffix)
    }

    /// UNVERIFIED: the names of the cookies that mean "signed in".
    var sessionCookieNames: Set<String> {
        switch self {
        case .substack: return SubstackEndpoints.sessionCookieNames
        case .economist: return []  // WebKit owns this session. Access is checked on each story.
        case .medium: return MediumDiscovery.sessionCookieNames
        case .nyt: return NYTDiscovery.sessionCookieNames
        }
    }
}

/// Reads the web view cookie store. Cookie VALUES never leave this type except into
/// HTTPCookieStorage; nothing here logs them.
@MainActor
enum WebSession {
    /// The default, persistent data store: sign-ins survive relaunches and are shared by the
    /// login sheet and the hidden NYT web view.
    static var dataStore: WKWebsiteDataStore { WKWebsiteDataStore.default() }

    static func cookies() async -> [HTTPCookie] {
        // Right after launch the web view's cookie store can answer empty until its data store has
        // been touched (seen 15/11/2026: "Not signed in" after every relaunch). Asking for the data
        // records first loads it; the cookies already copied to URLSession's storage cover the rest.
        _ = await dataStore.dataRecords(ofTypes: [WKWebsiteDataTypeCookies])
        var all: [HTTPCookie] = await withCheckedContinuation { continuation in
            dataStore.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        for cookie in HTTPCookieStorage.shared.cookies ?? []
        where !all.contains(where: { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path }) {
            all.append(cookie)
        }
        return all
    }

    /// Copy the service's cookies from the web view into the shared cookie storage that
    /// URLSession uses. Returns whether a session cookie was among them.
    @discardableResult
    static func copyCookies(for service: LoginService, alsoHosts extraHosts: [String] = []) async -> Bool {
        var signedIn = false
        // The web view's store has come back empty for a service after a relaunch while URLSession's
        // still held the session (15/11/2026). Put those cookies back so both stay signed in.
        let inWebView: [HTTPCookie] = await withCheckedContinuation { continuation in
            dataStore.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        for cookie in HTTPCookieStorage.shared.cookies ?? []
        where service.ownsCookieDomain(cookie.domain)
            && !inWebView.contains(where: { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path }) {
            await dataStore.httpCookieStore.setCookie(cookie)
        }
        for cookie in await cookies() {
            let domain = cookie.domain.lowercased()
            let matchesService = service.ownsCookieDomain(domain)
            // UNVERIFIED: a Substack publication on a custom domain keeps its own session cookie
            // on that domain; it only exists if the user also signed in there in the web view.
            let matchesExtra = extraHosts.contains { host in
                let h = host.lowercased()
                let bare = domain.trimmingCharacters(in: ["."])
                return !h.isEmpty && !bare.isEmpty && (bare == h || bare.hasSuffix("." + h) || h.hasSuffix("." + bare))
            }
            guard matchesService || matchesExtra else { continue }
            HTTPCookieStorage.shared.setCookie(cookie)
            if matchesService, service.sessionCookieNames.contains(cookie.name), !cookie.value.isEmpty {
                signedIn = true
            }
        }
        return signedIn
    }

    /// Logs which cookies each store holds for a service: names, domains and expiry, never values.
    static func logCookieState(_ service: LoginService, when: String) async {
        func describe(_ cookies: [HTTPCookie]) -> String {
            let mine = cookies.filter { service.ownsCookieDomain($0.domain) }
            let session = mine.filter { service.sessionCookieNames.contains($0.name) }.map { cookie -> String in
                let expiry = cookie.expiresDate.map { "\(Int($0.timeIntervalSinceNow / 86_400))d" } ?? "session-only"
                return "\(cookie.name)@\(cookie.domain)(\(expiry),len \(cookie.value.count))"
            }
            return "\(mine.count) cookie(s), session: [\(session.joined(separator: " "))]"
        }
        let web: [HTTPCookie] = await withCheckedContinuation { continuation in
            dataStore.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        AppLog.post("cookies \(service) \(when): webview \(describe(web)); urlsession \(describe(HTTPCookieStorage.shared.cookies ?? []))")
    }

    static func isSignedIn(_ service: LoginService) async -> Bool {
        let now = Date()
        return await cookies().contains { cookie in
            service.ownsCookieDomain(cookie.domain)
                && service.sessionCookieNames.contains(cookie.name)
                && !cookie.value.isEmpty
                && (cookie.expiresDate.map { $0 > now } ?? true)
        }
    }

    static func signOut(_ service: LoginService) async {
        if service == .economist {
            let types = WKWebsiteDataStore.allWebsiteDataTypes()
            let records = await dataStore.dataRecords(ofTypes: types).filter { $0.displayName == "economist.com" }
            await dataStore.removeData(ofTypes: types, for: records)
        }
        let store = dataStore.httpCookieStore
        for cookie in await cookies() where service.ownsCookieDomain(cookie.domain) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                store.delete(cookie) { continuation.resume() }
            }
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
    }
}

/// A plain web view on the shared persistent data store.
struct WebView: PlatformViewRepresentable {
    let url: URL

    @MainActor
    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WebSession.dataStore
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }

    #if canImport(UIKit)
    func makeUIView(context: Context) -> WKWebView { makeWebView() }
    func updateUIView(_ webView: WKWebView, context: Context) {}
    #else
    func makeNSView(context: Context) -> WKWebView { makeWebView() }
    func updateNSView(_ webView: WKWebView, context: Context) {}
    #endif
}

/// The sign-in sheet. The user signs in on the real site; on "Done" the cookies are copied.
struct LoginSheet: View {
    let service: LoginService
    let extraHosts: [String]
    let onFinish: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var signInLink = ""
    @State private var openedLink: URL?

    var body: some View {
        NavigationStack {
            Group {
                if let url = openedLink ?? service.loginURL {
                    VStack(spacing: 0) {
                        if service == .economist {
                            Text("Log in on The Economist website, then tap Use this session to sync front-page stories.")
                                .font(.footnote).padding(.horizontal)
                        }
                        WebView(url: url).id(url)
                        if service == .medium {
                            HStack {
                                TextField("Paste email sign-in link", text: $signInLink)
                                    .autocorrectionDisabled()
                                    #if os(iOS)
                                    .textInputAutocapitalization(.never)
                                    #endif
                                Button("Open") {
                                    guard let link = URL(string: signInLink.trimmingCharacters(in: .whitespacesAndNewlines)),
                                          link.scheme == "https", link.user == nil, link.password == nil, let host = link.host, MediumDiscovery.isMediumHost(host) else { return }
                                    openedLink = link
                                    signInLink = ""
                                }
                            }.padding()
                        }
                    }
                } else {
                    Text("No sign-in page is configured.")
                }
            }
            .navigationTitle(service.displayName)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(service == .economist ? "Use this session" : "Done") {
                        Task {
                            if service != .economist { await WebSession.copyCookies(for: service, alsoHosts: extraHosts) }
                            onFinish()
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}
