import Foundation
import Testing

@testable import BVXCore

private let known: Set<String> = ["bvx-8ou", "bvx-v49", "bvx-3", "whois-q1rfj"]

@Test("An id mentioned in prose is found")
func findsIDInProse() {
    let text = "work on bvx-8ou first to unblock this"
    let ranges = BeadReferences.ranges(in: text, known: known)
    #expect(ranges.count == 1)
    #expect(ranges.first.map { String(text[$0]) } == "bvx-8ou")
}

@Test("Several ids are found in order")
func findsSeveral() {
    let text = "bvx-v49 and bvx-3 both wait on bvx-8ou"
    let ranges = BeadReferences.ranges(in: text, known: known)
    #expect(ranges.map { String(text[$0]) } == ["bvx-v49", "bvx-3", "bvx-8ou"])
}

@Test(
    "No id format is assumed — short, long and foreign prefixes all resolve",
    arguments: ["bvx-3", "bvx-8ou", "whois-q1rfj"])
func formatAgnostic(id: String) {
    let text = "see \(id) for detail"
    #expect(BeadReferences.ranges(in: text, known: known).count == 1, "missed \(id)")
}

@Test(
    "An id the workspace does not hold stays plain text",
    arguments: [
        "see bvx-999 for detail",  // never existed
        "see bvx-8o for detail",  // truncated
        "see bvx-8ou-old for detail",  // longer token, not the id
        "see xbvx-8ou for detail",  // longer token, not the id
    ])
func unknownIDsAreNotLinked(text: String) {
    // A link that selects nothing is worse than no link, so membership — not
    // shape — is what decides.
    #expect(BeadReferences.ranges(in: text, known: known).isEmpty, "should not match: \(text)")
}

@Test(
    "Punctuation ends the token, so a cited id is still recognised",
    arguments: ["fix bvx-8ou.", "fix bvx-8ou, then stop", "(bvx-8ou)", "bvx-8ou's owner", "[bvx-8ou]"])
func punctuationBoundaries(text: String) {
    #expect(BeadReferences.ranges(in: text, known: known).count == 1, "missed in: \(text)")
}

@Test("An empty known set finds nothing")
func emptyKnownSet() {
    #expect(BeadReferences.ranges(in: "bvx-8ou", known: []).isEmpty)
}

@Test("Ranges never overlap")
func noOverlap() {
    let text = "bvx-8ou bvx-v49 bvx-3"
    let ranges = BeadReferences.ranges(in: text, known: known)
    for (a, b) in zip(ranges, ranges.dropFirst()) {
        #expect(a.upperBound <= b.lowerBound)
    }
}

// MARK: - URL scheme

@Test("A bead URL round-trips through the scheme")
func beadURLRoundTrip() throws {
    let url = try #require(BeadURL.open(bead: "bvx-8ou"))
    #expect(url.scheme == "bvx")
    #expect(BeadURL.bead(in: url) == "bvx-8ou")
    #expect(BeadURL.workspace(in: url) == nil)
}

@Test("A workspace and bead round-trip together, path escaping included")
func workspaceURLRoundTrip() throws {
    let path = "/Users/x/my project/repo"
    let url = try #require(BeadURL.open(bead: "bvx-3", workspace: path))
    #expect(BeadURL.workspace(in: url) == path)
    #expect(BeadURL.bead(in: url) == "bvx-3")
}

@Test("A foreign scheme yields nothing rather than a wrong id")
func foreignScheme() throws {
    let url = try #require(URL(string: "https://example.com/open?bead=bvx-3"))
    #expect(BeadURL.bead(in: url) == nil)
}
