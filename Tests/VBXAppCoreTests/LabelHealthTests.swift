import VBXCore
import Foundation
import Testing

@testable import VBXAppCore

private var fixturePath: String {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/demo")
        .path
}

@MainActor
@Test("Label analysis loads with the workspace")
func labelAnalysisLoads() async {
    let store = ProjectStore()
    await store.open(path: fixturePath)

    let analysis = store.labelAnalysis
    #expect(analysis.totalLabels > 0)
    #expect(!analysis.labels.isEmpty)

    // Counts must add up to the label total, or the summary bar lies.
    let sum = analysis.healthyCount + analysis.warningCount + analysis.criticalCount
    #expect(sum == analysis.totalLabels)

    await store.close()
}

@MainActor
@Test("Each label's counts are internally consistent")
func labelCountsConsistent() async {
    let store = ProjectStore()
    await store.open(path: fixturePath)

    for health in store.labelAnalysis.labels {
        #expect(!health.label.isEmpty)
        #expect(health.issueCount > 0)
        // Open and closed cannot exceed the total.
        #expect(health.openCount + health.closedCount <= health.issueCount)
        #expect((0...100).contains(health.health))
        #expect((0.0...1.0).contains(health.completion))
    }

    // Cross-check one label against the raw issues the engine returned.
    let engineLabels = Set(store.labelAnalysis.labels.map(\.label))
    let issueLabels = Set(store.issues.flatMap(\.labels))
    #expect(engineLabels.isSubset(of: issueLabels))

    await store.close()
}

@Test("Health level decoding is tolerant of unknown values")
func healthLevelDecoding() {
    #expect(HealthLevel(rawValue: "healthy") == .healthy)
    #expect(HealthLevel(rawValue: "warning") == .warning)
    #expect(HealthLevel(rawValue: "critical") == .critical)
    // A future level must not crash the view.
    #expect(HealthLevel(rawValue: "apocalyptic") == .unknown)
    #expect(HealthLevel(rawValue: "") == .unknown)
}

@Test("Completion is zero rather than NaN for an empty label")
func completionGuardsDivideByZero() throws {
    let json = #"{"label":"empty","issue_count":0,"closed_count":0}"#
    let health = try JSONDecoder().decode(LabelHealth.self, from: Data(json.utf8))
    #expect(health.completion == 0)
    #expect(!health.completion.isNaN)
}
