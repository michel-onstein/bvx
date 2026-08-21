import AppKit
import VBXAppCore
import VBXCore
import Foundation
import SwiftUI
import Testing

/// Renders SwiftUI views offscreen to PNG.
///
/// This needs no Screen Recording or Accessibility grant — `ImageRenderer`
/// draws through the process's own graphics context rather than capturing the
/// screen — so view rendering is verifiable in environments where screenshotting
/// the live app is not.
@MainActor
enum Snapshot {
    /// Where rendered images land, for a human to inspect after a run.
    static var outputDirectory: URL {
        let dir =
            ProcessInfo.processInfo.environment["VBX_SNAPSHOT_DIR"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vbx-snapshots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Renders `view` and writes it as `<name>.png`.
    ///
    /// Uses a real `NSHostingView` inside an offscreen window rather than
    /// `ImageRenderer`. That matters: `ImageRenderer` does not lay out
    /// `ScrollView` content, so every scrolling view (Board, Insights, Labels,
    /// Inspector) renders completely blank through it. Hosting performs a
    /// genuine AppKit layout and draw, which is also closer to what the running
    /// app puts on screen.
    @discardableResult
    static func render<V: View>(
        _ view: V,
        name: String,
        size: CGSize,
        scale: CGFloat = 2
    ) throws -> RenderResult {
        let root =
            view
            .frame(width: size.width, height: size.height)
            // An explicit ground colour: without it the render is transparent
            // and every "is it blank?" check becomes meaningless.
            .background(Color(nsColor: .windowBackgroundColor))

        let host = NSHostingView(rootView: AnyView(root))
        host.frame = CGRect(origin: .zero, size: size)

        // A window is required for SwiftUI to perform a full layout pass;
        // a detached view lays out only partially.
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.setFrame(host.frame, display: true)

        host.layoutSubtreeIfNeeded()
        // Let SwiftUI settle: lazy containers resolve their content on the
        // run loop, not synchronously inside layout.
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw SnapshotError.renderProducedNoImage(name)
        }
        host.cacheDisplay(in: host.bounds, to: rep)

        guard let cgImage = rep.cgImage else {
            throw SnapshotError.renderProducedNoImage(name)
        }
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw SnapshotError.encodingFailed(name)
        }

        let url = outputDirectory.appendingPathComponent("\(name).png")
        try png.write(to: url)

        return RenderResult(name: name, url: url, image: cgImage, bytes: png.count)
    }

    enum SnapshotError: Error, CustomStringConvertible {
        case renderProducedNoImage(String)
        case encodingFailed(String)

        var description: String {
            switch self {
            case .renderProducedNoImage(let n): "ImageRenderer produced no image for \(n)"
            case .encodingFailed(let n): "PNG encoding failed for \(n)"
            }
        }
    }
}

/// A rendered snapshot, with enough introspection to assert it is not blank.
struct RenderResult {
    let name: String
    let url: URL
    let image: CGImage
    let bytes: Int

    var width: Int { image.width }
    var height: Int { image.height }

    /// Fraction of pixels differing from the modal (background) colour.
    ///
    /// This is the substance check: a view that lays out but draws nothing
    /// still produces a valid PNG, so asserting on file size alone would pass
    /// for a blank canvas.
    func inkCoverage() -> Double {
        guard let data = image.dataProvider?.data,
            let ptr = CFDataGetBytePtr(data)
        else { return 0 }

        let bytesPerPixel = image.bitsPerPixel / 8
        let bytesPerRow = image.bytesPerRow
        guard bytesPerPixel >= 3 else { return 0 }

        // Sample on a grid; a full scan of a 2x-scaled view is needless work.
        let step = max(1, min(width, height) / 120)
        var histogram: [UInt32: Int] = [:]
        var sampled = 0

        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let r = UInt32(ptr[offset])
                let g = UInt32(ptr[offset + 1])
                let b = UInt32(ptr[offset + 2])
                // Quantise so antialiasing noise does not fragment the histogram.
                let key = (r / 16) << 16 | (g / 16) << 8 | (b / 16)
                histogram[key, default: 0] += 1
                sampled += 1
            }
        }
        guard sampled > 0, let background = histogram.values.max() else { return 0 }
        return Double(sampled - background) / Double(sampled)
    }

    /// Number of visually distinct colours, quantised. A view rendering only
    /// its background scores 1.
    func distinctColors() -> Int {
        guard let data = image.dataProvider?.data,
            let ptr = CFDataGetBytePtr(data)
        else { return 0 }
        let bytesPerPixel = image.bitsPerPixel / 8
        let bytesPerRow = image.bytesPerRow
        guard bytesPerPixel >= 3 else { return 0 }

        let step = max(1, min(width, height) / 120)
        var seen = Set<UInt32>()
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let r = UInt32(ptr[offset]) / 16
                let g = UInt32(ptr[offset + 1]) / 16
                let b = UInt32(ptr[offset + 2]) / 16
                seen.insert(r << 16 | g << 8 | b)
            }
        }
        return seen.count
    }
}

/// A ProjectStore loaded from the demo fixture, for hosting real views.
@MainActor
enum Fixture {
    static var path: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/demo")
            .path
    }

    /// Fully loaded store, including Phase-2 metrics, so metric-dependent views
    /// render their real content rather than placeholders.
    static func loadedStore() async -> ProjectStore {
        let store = ProjectStore()
        await store.open(path: path)
        await store.computePhase2()
        return store
    }

    /// A store over a private copy of the fixture.
    ///
    /// For anything that writes into the workspace — a baseline, a recipe.
    /// Swift Testing runs tests in parallel, so two of them writing to the
    /// shared fixture interfere: one test removing `<project>/.bv` takes
    /// another's file with it, and the failure surfaces in whichever test
    /// happened to lose the race. A private copy makes that impossible, and
    /// leaves the checkout untouched besides.
    ///
    /// Returns the store and the directory, which the caller removes when done.
    static func writableStore() async throws -> (store: ProjectStore, directory: URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vbx-fixture-\(UUID().uuidString)")
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: path), to: directory)

        let store = ProjectStore()
        await store.open(path: directory.path)
        await store.computePhase2()
        return (store, directory)
    }
}
