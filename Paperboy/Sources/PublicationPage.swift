import Foundation
import PaperboyCore
import WebKit
#if canImport(UIKit)
import UIKit
#endif

/// Each load owns its navigation and timeout, so sharing during a fetch cannot supersede it.
@MainActor
final class PublicationPage: NSObject, WKNavigationDelegate {

    private var web: WKWebView?
    private var loaded: CheckedContinuation<Void, Error>?

    static func snapshot(_ url: String, _ timeout: TimeInterval, _ capture: WebPublicationSource.Capture) async throws -> WebPublicationSource.Snapshot {
        try await PublicationPage().load(url: url, timeout: timeout, capture: capture)
    }

    private func load(url: String, timeout: TimeInterval, capture: WebPublicationSource.Capture) async throws -> WebPublicationSource.Snapshot {
        guard let address = URL(string: url), address.scheme == "https" else { throw URLError(.badURL) }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WebSession.dataStore
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        self.web = web
        web.navigationDelegate = self
        #if canImport(UIKit)
        web.alpha = 0
        web.isUserInteractionEnabled = false
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            .first { $0.isKeyWindow }?.insertSubview(web, at: 0)
        #endif
        defer {
            web.stopLoading()
            web.navigationDelegate = nil
            #if canImport(UIKit)
            web.removeFromSuperview()
            #endif
            self.web = nil
        }
        let watchdog = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
            self?.finish(.failure(URLError(.timedOut)))
            self?.web?.stopLoading()
        }
        defer { watchdog.cancel() }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                loaded = continuation
                web.load(URLRequest(url: address))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(.failure(CancellationError()))
                self?.web?.stopLoading()
            }
        }
        try await Task.sleep(for: .milliseconds(500))
        try Task.checkCancellation()
        guard let finalURL = web.url else { throw URLError(.badURL) }
        switch capture {
        case .links:
            // Exclude sidebar recommendations and account/navigation links.
            let html = try await web.callAsyncJavaScript("""
                const main = document.querySelector('main, [role="main"]') || (economist ? null : document.body);
                if (!main) return '';
                const chrome = 'aside, nav, footer, [role="complementary"], [role="navigation"], [role="banner"]';
                return Array.from(main.querySelectorAll('a[href]'))
                    .filter(a => !a.closest(chrome) && (economist
                        ? !a.closest('[hidden], [aria-hidden="true"]') && a.getClientRects().length > 0
                        : !a.closest('header')))
                    .map(a => '<a href="' + a.href.replace(/&/g, '&amp;').replace(/"/g, '&quot;') + '"></a>').join('');
                """, arguments: ["economist": WebPublicationSource.isEconomistPublisherURL(address)], in: nil, contentWorld: .defaultClient) as? String ?? ""
            return .init(url: finalURL, html: html)
        case .economistStory:
            guard WebPublicationSource.isEconomistPublisherURL(finalURL) else { throw PublicationPageError.openOnWebsite }
            let html = try await ReaderModeExtractor.economistSnapshot(in: web)
            return .init(url: finalURL, html: html)
        case .mediumStory:
            let html = try await web.evaluateJavaScript("document.documentElement.outerHTML") as? String ?? ""
            return .init(url: finalURL, html: html)
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        let continuation = loaded
        loaded = nil
        continuation?.resume(with: result)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.failure(URLError(.cannotLoadFromNetwork))) }
}
