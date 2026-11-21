import Foundation
import PaperboyCore
import WebKit

/// Signs the web session in to a Substack publication that lives on its own domain.
///
/// The Substack session cookie belongs to substack.com, so a publication such as slowboring.com
/// never sees it and answers paid posts with the free preview. Substack's own "Sign in" link on
/// such a site goes to `substack.com/sign-in?for_pub=<subdomain>`; for someone already signed in
/// there it redirects back to the publication, which then sets its own session cookie. This loads
/// that link in a hidden web view and copies the resulting cookie to URLSession's storage.
@MainActor
final class SubstackDomainSession: NSObject {
    static let shared = SubstackDomainSession()

    private var webView: WKWebView?
    /// Hosts already tried since launch: a sign-in that did not work is not repeated every fetch.
    private var attempted: Set<String> = []

    private func cookies(for host: String) async -> [HTTPCookie] {
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return await WebSession.cookies().filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return domain == host || domain == bare || host.hasSuffix("." + domain)
        }
    }

    private func hasSession(_ cookies: [HTTPCookie]) -> Bool {
        cookies.contains { SubstackEndpoints.sessionCookieNames.contains($0.name) && !$0.value.isEmpty }
    }

    /// True when URLSession now holds a session cookie for `host`.
    func ensure(host: String, subdomain: String) async -> Bool {
        var found = await cookies(for: host)
        if !hasSession(found) {
            guard attempted.insert(host).inserted,
                  let url = URL(string: "https://substack.com/sign-in?redirect=%2F&for_pub=\(subdomain)") else { return false }
            let view = webView ?? makeWebView()
            webView = view
            view.load(URLRequest(url: url))
            // The redirect chain ends on the publication's site; give it up to 20 s.
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(500))
                found = await cookies(for: host)
                if hasSession(found) { break }
            }
            // The host only: the redirect URLs carry one-time sign-in tokens.
            AppLog.post("Substack sign-in on \(host): \(hasSession(found) ? "ok" : "no session cookie"), ended at \(view.url?.host ?? "?")")
            view.stopLoading()
        }
        guard hasSession(found) else { return false }
        for cookie in found { HTTPCookieStorage.shared.setCookie(cookie) }
        return true
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WebSession.dataStore
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        #if canImport(UIKit)
        view.alpha = 0
        view.isUserInteractionEnabled = false
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .insertSubview(view, at: 0)
        #endif
        return view
    }
}
