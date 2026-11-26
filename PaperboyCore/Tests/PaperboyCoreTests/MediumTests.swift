import Foundation
import Testing
@testable import PaperboyCore

@Suite struct MediumTests {
    @Test func followingLinksIncludeCustomPublicationsAndDeduplicateTracking() {
        let html = """
            <a href="/@writer/story-one-123456abcdef?source=following">One</a>
            <a href="https://medium.com/@writer/story-one-123456abcdef?source=other">Duplicate</a>
            <a href="https://writing.example/story-two-abcdef123456">Custom publication</a>
            <a href="https://medium.com/@writer">Profile</a>
            <a href="https://medium.com/tag/science">Topic</a>
            <a href="javascript:alert(1)">Bad</a>
            <a href="http://medium.com/@writer/story-three-012345abcdef">Insecure</a>
            """
        #expect(MediumDiscovery.storyLinks(in: html) == [
            "https://medium.com/@writer/story-one-123456abcdef",
            "https://writing.example/story-two-abcdef123456",
        ])
    }

    @Test func hostMatchingUsesDomainBoundary() {
        #expect(MediumDiscovery.isMediumHost("writer.medium.com"))
        #expect(!MediumDiscovery.isMediumHost("notmedium.com"))
        #expect(!MediumDiscovery.isMediumHost("medium.com.example"))
        #expect(!MediumDiscovery.isStoryURL("https://other.example/story-123456abcdef"))
        #expect(!MediumDiscovery.isStoryURL("https://medium.com/@writer"))
    }
}
