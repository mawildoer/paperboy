import Foundation
import PaperboyCore
import WebKit
#if canImport(UIKit)
import UIKit
#endif

/// Signs the web session in to a Substack publication that lives on its own domain.
///
/// The Substack session cookie belongs to substack.com, so a publication such as slowboring.com
/// never sees it and answers paid posts with the free preview. Substack's own "Sign in" link on
/// such a site goes to `substack.com/sign-in?for_pub=<subdomain>`; for someone already signed in
/// there it redirects back to the publication, which then sets its own session cookie. This loads
/// that link in a dedicated web view. Only the background JSON path also syncs its cookie jar.
@MainActor
final class SubstackDomainSession: NSObject {
    static let shared = SubstackDomainSession()

    /// Hosts already tried since launch: a sign-in that did not work is not repeated every fetch.
    private var attempted: Set<String> = []

    private func cookies(_ all: [HTTPCookie], for host: String) -> [HTTPCookie] {
        let host = host.lowercased()
        return all.filter { cookie in
            let domain = cookie.domain.lowercased()
            if domain.hasPrefix(".") { return host == domain.dropFirst() || host.hasSuffix(domain) }
            return host == domain
        }
    }

    private func hasSession(_ cookies: [HTTPCookie]) -> Bool {
        cookies.contains {
            SubstackEndpoints.sessionCookieNames.contains($0.name) && !$0.value.isEmpty && ($0.expiresDate ?? .distantFuture) > Date()
        }
    }

    /// A refused share only needs this flow when the browser has the central session but
    /// the publication hasn't acquired its own. WebKit scopes both sessions throughout.
    func signInForShare(host: String, subdomain: String) async throws -> Bool {
        let all = await WebSession.dataStore.httpCookieStore.allCookies()
        guard hasSession(cookies(all, for: "substack.com")), !hasSession(cookies(all, for: host)) else { return false }
        return try await signIn(host: host, subdomain: subdomain)
    }

    private func signIn(host: String, subdomain: String) async throws -> Bool {
        guard subdomain.wholeMatch(of: #/[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?/#) != nil,
              let url = URL(string: "https://substack.com/sign-in?redirect=%2F&for_pub=\(subdomain)") else { return false }
        try Task.checkCancellation()
        let view = makeWebView()
        defer {
            view.stopLoading()
            #if canImport(UIKit)
            view.removeFromSuperview()
            #endif
        }
        view.load(URLRequest(url: url))
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(500))
            if hasSession(cookies(await WebSession.dataStore.httpCookieStore.allCookies(), for: host)) { return true }
        }
        return false
    }

    /// True when URLSession now holds a session cookie for the background JSON request.
    func ensure(host: String, subdomain: String) async -> Bool {
        var found = cookies(await WebSession.cookies(), for: host)
        if !hasSession(found) {
            guard attempted.insert(host).inserted,
                  (try? await signIn(host: host, subdomain: subdomain)) == true else { return false }
            found = cookies(await WebSession.cookies(), for: host)
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
