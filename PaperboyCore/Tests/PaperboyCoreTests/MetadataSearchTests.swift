import Testing
@testable import PaperboyCore

@Suite struct MetadataSearchTests {
    @Test func combinesFieldsAndIgnoresCaseAccentsAndPunctuation() {
        #expect(MetadataSearch.score("GARCIA transit nyt", title: "Transit: a new study", author: "José García", source: "New York Times") != nil)
        #expect(MetadataSearch.score("garcia missing", title: "Transit", author: "José García", source: "Journal") == nil)
    }
    @Test func handlesPrefixesAndSmallTyposWithoutMatchingEveryShortToken() {
        #expect(MetadataSearch.score("tranpsort", title: "Transport economics", author: "", source: "") != nil)
        #expect(MetadataSearch.score("econ", title: "Transport economics", author: "", source: "") != nil)
        #expect(MetadataSearch.score("ai", title: "Urban planning", author: "Ada Writer", source: "Science") == nil)
        #expect(MetadataSearch.score("unrelated", title: "Transport", author: "Ada", source: "Journal") == nil)
    }
    @Test func exactMatchesRankAboveTyposAndBlankQueryKeepsEverything() {
        let exact = MetadataSearch.score("transport", title: "Transport", author: "", source: "")!
        let typo = MetadataSearch.score("transprot", title: "Transport", author: "", source: "")!
        #expect(exact > typo)
        #expect(MetadataSearch.score("  ", title: "", author: "", source: "") == 0)
    }
}
