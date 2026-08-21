import Foundation
import Testing

@testable import VBXCore

private let known: Set<String> = ["vbx-8ou", "vbx-v49", "vbx-3", "whois-q1rfj"]

@Test("An id mentioned in prose is found")
func findsIDInProse() {
    let text = "work on vbx-8ou first to unblock this"
    let ranges = BeadReferences.ranges(in: text, known: known)
    #expect(ranges.count == 1)
    #expect(ranges.first.map { String(text[$0]) } == "vbx-8ou")
}

@Test("Several ids are found in order")
func findsSeveral() {
    let text = "vbx-v49 and vbx-3 both wait on vbx-8ou"
    let ranges = BeadReferences.ranges(in: text, known: known)
    #expect(ranges.map { String(text[$0]) } == ["vbx-v49", "vbx-3", "vbx-8ou"])
}

@Test(
    "No id format is assumed — short, long and foreign prefixes all resolve",
    arguments: ["vbx-3", "vbx-8ou", "whois-q1rfj"])
func formatAgnostic(id: String) {
    let text = "see \(id) for detail"
    #expect(BeadReferences.ranges(in: text, known: known).count == 1, "missed \(id)")
}

@Test(
    "An id the workspace does not hold stays plain text",
    arguments: [
        "see vbx-999 for detail",  // never existed
        "see vbx-8o for detail",  // truncated
        "see vbx-8ou-old for detail",  // longer token, not the id
        "see xvbx-8ou for detail",  // longer token, not the id
    ])
func unknownIDsAreNotLinked(text: String) {
    // A link that selects nothing is worse than no link, so membership — not
    // shape — is what decides.
    #expect(BeadReferences.ranges(in: text, known: known).isEmpty, "should not match: \(text)")
}

@Test(
    "Punctuation ends the token, so a cited id is still recognised",
    arguments: ["fix vbx-8ou.", "fix vbx-8ou, then stop", "(vbx-8ou)", "vbx-8ou's owner", "[vbx-8ou]"])
func punctuationBoundaries(text: String) {
    #expect(BeadReferences.ranges(in: text, known: known).count == 1, "missed in: \(text)")
}

@Test("An empty known set finds nothing")
func emptyKnownSet() {
    #expect(BeadReferences.ranges(in: "vbx-8ou", known: []).isEmpty)
}

@Test("Ranges never overlap")
func noOverlap() {
    let text = "vbx-8ou vbx-v49 vbx-3"
    let ranges = BeadReferences.ranges(in: text, known: known)
    for (a, b) in zip(ranges, ranges.dropFirst()) {
        #expect(a.upperBound <= b.lowerBound)
    }
}

// MARK: - URL scheme

@Test("A bead URL round-trips through the scheme")
func beadURLRoundTrip() throws {
    let url = try #require(BeadURL.open(bead: "vbx-8ou"))
    #expect(url.scheme == "vbx")
    #expect(BeadURL.bead(in: url) == "vbx-8ou")
    #expect(BeadURL.workspace(in: url) == nil)
}

@Test("A workspace and bead round-trip together, path escaping included")
func workspaceURLRoundTrip() throws {
    let path = "/Users/x/my project/repo"
    let url = try #require(BeadURL.open(bead: "vbx-3", workspace: path))
    #expect(BeadURL.workspace(in: url) == path)
    #expect(BeadURL.bead(in: url) == "vbx-3")
}

@Test("A foreign scheme yields nothing rather than a wrong id")
func foreignScheme() throws {
    let url = try #require(URL(string: "https://example.com/open?bead=vbx-3"))
    #expect(BeadURL.bead(in: url) == nil)
}
