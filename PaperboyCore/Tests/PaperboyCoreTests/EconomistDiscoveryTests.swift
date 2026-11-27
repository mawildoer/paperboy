import Foundation
import Testing
@testable import PaperboyCore

@Suite struct EconomistDiscoveryTests {
    private let origin = "https://www.economist.com"
    private let story = "/the-world-this-week/2026/11/26/business"
    private let feature = "/interactive/1843/2026/11/27/can-the-worlds-biggest-snack-firm-survive-the-ozempic-revolution"

    @Test func homepageAndStoryHosts() {
        #expect(EconomistDiscovery.frontPageURL == origin + "/")
        for host in ["economist.com", "WWW.ECONOMIST.COM"] {
            #expect(EconomistDiscovery.isPublisherHost(host))
        }
        for host in ["econ.st", "myaccount.economist.com", "economist.com.example", "noteconomist.com", "www.economist.com."] {
            #expect(!EconomistDiscovery.isPublisherHost(host))
        }
    }

    @Test func giftAccessAndIdentityAreIndependent() throws {
        let shared = try #require(URL(string: "HTTPS://ECONOMIST.COM:443" + story + "/?utm_source=mail&giftId=a%2Bb%2Fc%3D&utm_campaign=gifted_article#top"))
        let canonical = try #require(EconomistDiscovery.storyURL(shared))
        let load = try #require(EconomistDiscovery.loadingURL(for: shared))
        #expect(canonical.absoluteString == origin + story)
        #expect(load.absoluteString == origin + story + "?giftId=a%2Bb%2Fc%3D")
        #expect(EconomistDiscovery.storyURL(load) == canonical)
        for query in ["?utm_campaign=gifted_article", "?giftId=", "?giftId", "?giftIdFake=value", "#giftId=value"] {
            let other = try #require(URL(string: origin + story + query))
            #expect(EconomistDiscovery.loadingURL(for: other) == canonical)
        }
    }

    @Test func syncUsesVisibleMainAnchorsInFirstOccurrenceOrder() {
        let other = "/britain/2024/02/29/another-story"
        let html = """
            <html><body><a href="\(other)">Before main</a>
            <div role="main">
              <nav><a href="\(other)">Menu</a></nav>
              <a data-href="\(other)">Placeholder</a><link href="\(other)">
              <script>let ad = '<a href="\(other)">';</script>
              <!-- <a href="\(other)"> -->
              <template><a href="\(other)">Template</a></template>
              <span aria-hidden="true"><a href="\(other)">Hidden</a></span>
              <section><article><header><A HREF='\(feature)'>Feature</A></header></article></section>
              <a href="\(story)?utm_source=home&amp;giftId=demo">Story</a>
              <a href="//economist.com\(feature)/#comments">Feature again</a>
              <a href="https://ECONOMIST.com:443\(story)?utm_campaign=other">Story again</a>
              <aside><a href="\(other)">Sidebar</a></aside>
            </div><footer><a href="\(other)">After main</a></footer></body></html>
            """
        #expect(EconomistDiscovery.storyLinks(in: html) == [origin + feature, origin + story])
        #expect(EconomistDiscovery.storyLinks(in: "<html><body><a href='\(story)'>Index</a></body></html>").isEmpty)
        #expect(EconomistDiscovery.storyLinks(in: "<main><a href='\(other)'>Leap day</a></main>") == [origin + other])
    }

    @Test func prefilteredFragmentCanContainRelativeOrAbsoluteLinks() {
        let html = """
            <a href=the-world-this-week/2026/11/26/business></a>
            <a href="\(origin)/the-world-this-week/2026/11/26/%62usiness?utm_campaign=card"></a>
            <a href="https://economist.com\(feature)"></a>
            """
        #expect(EconomistDiscovery.storyLinks(in: html) == [origin + story, origin + feature])
    }

    @Test(arguments: ["/graphic-detail/coronavirus-excess-deaths-tracker", "/interactive/inflation-tracker",
                      "/interactive/us-2024-election/prediction-model/president",
                      "/news/finance-and-economics/21571940-crunch-time", "/node/21563714"])
    func explicitUndatedShareStaysOutOfSync(_ path: String) throws {
        let url = try #require(URL(string: "https://economist.com" + path + "/?giftId=sample&utm_campaign=gifted_article"))
        #expect(EconomistDiscovery.loadingURL(for: url)?.absoluteString == origin + path + "?giftId=sample")
        #expect(EconomistDiscovery.storyURL(url)?.absoluteString == origin + path)
        #expect(EconomistDiscovery.storyLinks(in: "<a href='\(url.absoluteString)'></a>").isEmpty)
    }

    @Test(arguments: ["http://www.economist.com", "ftp://economist.com", "https://econ.st",
                      "https://account.economist.com", "https://economist.com.example",
                      "https://www.economist.com@other.example", "https://reader:pw@economist.com",
                      "https://@economist.com", "https://www.economist.com:8443"])
    func unsafeOriginNeverRoutesToRenderer(_ authority: String) throws {
        let url = try #require(URL(string: authority + story + "?giftId=sample"))
        #expect(EconomistDiscovery.storyURL(url) == nil)
        #expect(EconomistDiscovery.loadingURL(for: url) == nil)
        #expect(EconomistDiscovery.storyLinks(in: "<a href='\(url.absoluteString)'></a>").isEmpty)
    }

    @Test(arguments: ["/", "/leaders", "/weeklyedition/2026-11-28", "/interactive/graphic-detail",
                      "/the-world-this-week/2026/11/26/", "/science-and-technology/2025/02/29/impossible",
                      "/leaders/2026/1/01/short-month", "/leaders/2026/00/27/out-of-range", "/leaders/2026-11-26",
                      "/news/subscribe/12345-promo", "/interactive/graphic-detail/2024/02/30/impossible",
                      "/leaders/2026/11/26/story/next", "/leaders/2026/11/26/file.jpg",
                      "/leaders%2F2026/11/26/encoded-separator", "/leaders//2026/11/26/story",
                      "/newsletters/2026/11/26/morning", "/podcasts/2026/11/26/episode",
                      "/subscribe/2026/11/26/offer", "/api/leaders/2026/11/26/story",
                      "/subscribe?next=/leaders/2026/11/26/story", "/node/search"])
    func nonStoryPathsFailBothRoutes(_ path: String) throws {
        let url = try #require(URL(string: origin + path))
        #expect(EconomistDiscovery.storyURL(url) == nil)
        #expect(EconomistDiscovery.loadingURL(for: url) == nil)
        #expect(EconomistDiscovery.storyLinks(in: "<a href='\(path)'></a>").isEmpty)
    }
}
