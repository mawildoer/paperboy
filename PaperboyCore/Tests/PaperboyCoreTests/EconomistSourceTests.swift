import Foundation
import Testing
@testable import PaperboyCore

@MainActor
@Suite struct EconomistSourceTests {
    private let story = "https://www.economist.com/business/2026/11/25/reading-the-shipping-data"
    private let headline = "Reading the shipping data"
    private var html: String {
        let paragraph = "<p>The latest shipping figures show how the cost of moving goods between ports has changed over the past year. Analysts compared freight rates, delivery times and inventories to understand where the largest delays occurred.</p>"
        return "<html><head><title>\(headline)</title><meta property='article:published_time' content='2026-11-25T10:11:12Z'></head><body><main><article><h1>\(headline)</h1>\(String(repeating: paragraph, count: 4))</article></main></body></html>"
    }

    @Test func refreshCachesOneStoryAndSharingQueuesThatSameEpub() async throws {
        let directory = try makeTempDirectory("paperboy-economist-refresh")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ArticleStore(directory: directory)
        var loadedStories = [String]()
        let source = WebPublicationSource(.economist) { address, _, capture in
            let url = try #require(URL(string: address))
            if capture == .links {
                return .init(url: url, html: "<a href='\(story)?utm_source=test'></a><a href='\(story)'></a>")
            }
            loadedStories.append(address)
            return .init(url: url, html: html)
        }
        for expected in [1, 0] {
            let result = await source.fetchNew(store: store, maxPerFetch: 1, oldest: .distantPast, deadline: Date().addingTimeInterval(15))
            #expect(result.added == expected && result.failed == 0)
        }
        let record = try #require(await store.all().first)
        #expect(loadedStories == [story])
        #expect(record.title == headline && record.source == "The Economist" && record.load == .off)
        #expect(record.date == ISODate.parse("2026-11-25T10:11:12Z"))
        let original = try await store.epub(for: record.id)
        let safari = try await source.sharedArticle(url: URL(string: story + "?utm_source=safari")!,
                                                   snapshot: html.replacingOccurrences(of: headline, with: "Stale preview"),
                                                   title: "Stale preview")
        #expect(safari.title == headline)
        let queued = try await store.addShared(safari)
        #expect(queued.id == record.id && queued.load == .load && loadedStories == [story, story])
        #expect(try await store.epub(for: queued.id) == original)
    }

    @Test func urlOnlyShareKeepsGiftAccessButStoresThePublisherIdentity() async throws {
        var addresses = [String]()
        let gift = story + "?giftId=granted%2Btoken"
        let source = WebPublicationSource(.economist) { address, _, capture in
            #expect(capture == .economistStory)
            addresses.append(address)
            return .init(url: URL(string: gift)!, html: html)
        }
        let shared = try await source.sharedArticle(url: URL(string: gift + "&utm_source=app")!)
        #expect(shared.url == story && shared.title == headline)
        let short = URL(string: "https://econ.st/test-share")!
        let redirected = try await source.sharedArticle(url: short)
        #expect(redirected.id == shared.id && addresses == [gift, short.absoluteString])
    }

    @Test func oneLockedStoryDoesNotHideTheNextReadableOne() async throws {
        let directory = try makeTempDirectory("paperboy-economist-mixed")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ArticleStore(directory: directory)
        let locked = story + "-locked"
        let source = WebPublicationSource(.economist) { address, _, capture in
            if address == locked { throw EconomistAccessError.accessRequired }
            let listing = "<a href='\(locked)'></a><a href='\(story)'></a>"
            return .init(url: URL(string: address)!, html: capture == .links ? listing : html)
        }
        let summary = await source.fetchNew(store: store, maxPerFetch: 2, oldest: .distantPast, deadline: Date().addingTimeInterval(15))
        #expect(summary.failed == 1 && summary.added == 1)
        #expect(await store.all().map(\.url) == [story])
    }

    @Test func gatedStoryIsNeverCachedOrQueued() async throws {
        let directory = try makeTempDirectory("paperboy-economist-access")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ArticleStore(directory: directory)
        let gated = html.replacingOccurrences(of: "</article>", with: "<div data-testid='paywall'>Subscribe to continue reading</div></article>")
        let source = WebPublicationSource(.economist) { address, _, capture in
            .init(url: URL(string: address)!, html: capture == .links ? "<a href='\(story)'></a>" : gated)
        }
        let summary = await source.fetchNew(store: store, maxPerFetch: 1, oldest: .distantPast, deadline: Date().addingTimeInterval(15))
        #expect(summary.failed == 1 && summary.added == 0)
        await #expect(throws: EconomistAccessError.self) {
            try await source.sharedArticle(url: URL(string: story)!)
        }
        #expect(await store.all().isEmpty)
    }
}
