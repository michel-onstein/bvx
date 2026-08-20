import BVXCore
import Foundation
import Testing

@testable import BVXEngine

private var fixturePath: String {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/demo")
        .path
}

@Test("Markdown export renders bv's report with a Mermaid diagram")
func exportMarkdown() async throws {
    let engine = BeadsEngine()
    _ = try await engine.open(path: fixturePath)
    defer { Task { await engine.close() } }

    let report = try await engine.exportMarkdown(title: "Test Report")

    #expect(report.markdown.hasPrefix("# Test Report"))
    #expect(report.bytes == report.markdown.utf8.count)
    // Nothing was written, because no path was given.
    #expect(report.path.isEmpty)

    // The diagram is the reason this goes through the engine rather than being
    // reimplemented in Swift.
    #expect(report.markdown.contains("```mermaid"))
    #expect(report.markdown.contains("## Dependency Graph"))
    #expect(report.markdown.contains("## Summary"))

    // Every bead should appear in the report.
    for id in ["bvx-1", "bvx-3", "bvx-18"] {
        #expect(report.markdown.contains(id), "report omits \(id)")
    }

    await engine.close()
}

@Test("Markdown export writes to disk when given a path")
func exportMarkdownToFile() async throws {
    let engine = BeadsEngine()
    _ = try await engine.open(path: fixturePath)

    let out = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("bvx-report-\(UUID()).md")
    defer { try? FileManager.default.removeItem(at: out) }

    let report = try await engine.exportMarkdown(title: "Written", path: out.path)
    #expect(report.path == out.path)

    let onDisk = try String(contentsOf: out, encoding: .utf8)
    #expect(onDisk == report.markdown, "the file must match what was returned")
    #expect(onDisk.contains("# Written"))

    await engine.close()
}

@Test("Exporting to an unwritable path reports an error")
func exportMarkdownBadPath() async throws {
    let engine = BeadsEngine()
    _ = try await engine.open(path: fixturePath)

    await #expect(throws: (any Error).self) {
        _ = try await engine.exportMarkdown(
            title: "Nope", path: "/definitely/not/a/directory/report.md")
    }
    await engine.close()
}
