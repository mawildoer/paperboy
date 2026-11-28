import Foundation
import Testing
@testable import PaperboyCore

@MainActor
@Suite struct SharedArticleImportTests {
    private func story(_ url: String, text: String) -> Article {
        Article(url: url, source: "Publication", title: "The story", author: "Writer", date: Date(timeIntervalSince1970: 1_765_000_000),
                bodyXHTML: "<p>\(text)</p>")
    }

    @Test(arguments: [
        ("https://news.substack.com/p/the-story", SharedPublisher.substack),
        ("https://example.press/p/the-story", .substack),
        ("https://medium.com/@reader/the-story-abbadabbad00", .medium),
        ("https://www.nytimes.com/2026/11/28/business/a-story.html", .nyt),
        ("https://www.economist.com/business/2026/11/28/a-story", .economist)
    ])
    func reshareFetchesWithOriginalQueryAndReplacesCachedPreview(_ address: String, _ publisher: SharedPublisher) async throws {
        let directory = try makeTempDirectory("known-share")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ArticleStore(directory: directory)
        let previous = try await store.add(story(address, text: "Earlier teaser"), load: .lock)
        let share = SharedPage(url: address + "?giftId=sample", html: "<article>Another browser’s preview</article>")
        var navigations = [URL]()
        let saved = try await SharedArticleImport.run(share, store: store, substackPublications: ["example.press"]) { detected, url in
            #expect(detected == publisher)
            navigations.append(url)
            return story(address, text: "Full text from the Paperboy session.")
        } fetchOther: { _ in
            Issue.record("A recognized share reached the snapshot importer")
            throw URLError(.badURL)
        }
        #expect(navigations.map(\.absoluteString) == [share.url])
        #expect(saved.id == previous.id && saved.load == .lock && saved.fetchedAt == previous.fetchedAt)
        #expect(saved.preview == "Full text from the Paperboy session.")
        #expect(saved.sharedPublisher == publisher)
        #expect(await store.all().count == 1)
    }

    @Test func customPublisherSurvivesURLOnlyReshareAndOfflineErrorsKeepTheGoodCopy() async throws {
        let directory = try makeTempDirectory("session-share")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ArticleStore(directory: directory)
        let address = "https://an-independent-publication.example/my-story-abbadabbad00"
        let existing = try await store.add(story(address, text: "Complete cached article"), publisher: .medium)
        let original = try await store.epub(for: existing.id)
        var didNavigate = false
        do {
            _ = try await SharedArticleImport.run(SharedPage(url: address), store: store, substackPublications: []) { publisher, _ in
                #expect(publisher == .medium)
                didNavigate = true
                throw URLError(.notConnectedToInternet)
            } fetchOther: { _ in
                Issue.record("A previous publisher import lost its identity")
                throw URLError(.badURL)
            }
            Issue.record("An offline publisher fetch reported success")
        } catch let error as URLError { #expect(error.code == .notConnectedToInternet) }
        #expect(didNavigate)
        #expect(try await store.epub(for: existing.id) == original)
        #expect(await store.article(existing.id) == existing)
    }

    @Test func unknownSiteUsesSharedPageThenReusesItsCachedArticle() async throws {
        let directory = try makeTempDirectory("general-share")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ArticleStore(directory: directory)
        let page = SharedPage(url: "https://ordinary.example/p/story", html: "<article>A shared page</article>")
        var extractions = 0
        for _ in 0..<2 {
            _ = try await SharedArticleImport.run(page, store: store, substackPublications: []) { _, _ in
                Issue.record("An unrelated /p/ URL used a publisher session")
                throw URLError(.badURL)
            } fetchOther: { input in
                #expect(input == page)
                extractions += 1
                return (story(input.url, text: "From the share"), nil)
            }
        }
        #expect(extractions == 1)
    }
}
