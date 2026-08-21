import AppKit
import Foundation
import Testing

/// Guards the committed app icon.
///
/// `Resources/vbx.icns` is a build input, not a build product — `build-app.sh`
/// copies it straight into the bundle — so nothing else would notice if it went
/// missing, lost a representation, or was regenerated from artwork that renders
/// blank. `build-icon.sh --check` covers the file's shape; these tests cover the
/// pixels, including the one property that quietly rots when artwork gains
/// detail: that the icon still reads at menu-bar size.
private var iconURL: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Resources/vbx.icns")
}

/// One representation redrawn into a known 8-bit RGBA buffer, so pixel reads do
/// not depend on whatever format the .icns happens to store.
private struct Raster {
    let width: Int
    let height: Int
    let pixels: [UInt8]  // RGBA, premultiplied-last

    init?(_ rep: NSImageRep) {
        let w = rep.pixelsWide
        let h = rep.pixelsHigh
        guard w > 0, h > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard
            let ctx = buffer.withUnsafeMutableBytes({ raw in
                CGContext(
                    data: raw.baseAddress, width: w, height: h,
                    bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            })
        else { return nil }

        let saved = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let drawn = rep.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.current = saved
        guard drawn else { return nil }

        self.width = w
        self.height = h
        self.pixels = buffer
    }

    func rgba(x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        let o = (y * width + x) * 4
        return (pixels[o], pixels[o + 1], pixels[o + 2], pixels[o + 3])
    }

    /// Fraction of pixels inside the icon body that sit on a hard edge.
    ///
    /// Counting distinct colours would not work here: the background is a
    /// gradient, so a tile with no artwork at all still shows hundreds of
    /// shades. What separates artwork from a bare tile is *local contrast* —
    /// beads and the X have sharp boundaries, a smooth gradient does not. This
    /// is also the right measure for the small sizes, because losing legibility
    /// when downscaled is precisely edges blurring away.
    ///
    /// Sampling is confined to the body: the transparent squircle margin would
    /// otherwise register as a huge edge and mask the artwork's absence.
    func edgeDensity() -> Double {
        let inset = Int((Double(width) * 0.16).rounded())
        let delta = max(1, Int((Double(width) / 256.0).rounded()))
        let threshold = 24
        var edges = 0
        var sampled = 0

        for y in stride(from: inset, to: height - inset - delta, by: 1) {
            for x in stride(from: inset, to: width - inset - delta, by: 1) {
                let here = rgba(x: x, y: y)
                let right = rgba(x: x + delta, y: y)
                let down = rgba(x: x, y: y + delta)
                let jump = max(
                    channelDistance(here, right),
                    channelDistance(here, down))
                if jump > threshold { edges += 1 }
                sampled += 1
            }
        }
        guard sampled > 0 else { return 0 }
        return Double(edges) / Double(sampled)
    }

    /// Largest per-channel difference between two pixels, alpha included.
    private func channelDistance(
        _ a: (UInt8, UInt8, UInt8, UInt8), _ b: (UInt8, UInt8, UInt8, UInt8)
    ) -> Int {
        max(
            max(abs(Int(a.0) - Int(b.0)), abs(Int(a.1) - Int(b.1))),
            max(abs(Int(a.2) - Int(b.2)), abs(Int(a.3) - Int(b.3))))
    }
}

private func representations() throws -> [Int: NSImageRep] {
    let image = try #require(NSImage(contentsOf: iconURL), "vbx.icns did not decode")
    var byWidth: [Int: NSImageRep] = [:]
    for rep in image.representations where rep.pixelsWide == rep.pixelsHigh {
        byWidth[rep.pixelsWide] = rep
    }
    return byWidth
}

private func raster(_ size: Int) throws -> Raster {
    let reps = try representations()
    let rep = try #require(reps[size], "no \(size)px representation")
    return try #require(Raster(rep), "\(size)px representation did not rasterise")
}

@Test("The committed icon carries every size macOS asks for")
func iconHasEveryRepresentation() throws {
    #expect(
        FileManager.default.fileExists(atPath: iconURL.path),
        "Resources/vbx.icns is missing — run ./scripts/build-icon.sh")

    let reps = try representations()
    // 1x and 2x pairs collapse to this set of pixel dimensions.
    for size in [16, 32, 64, 128, 256, 512, 1024] {
        #expect(reps[size] != nil, "no \(size)px representation")
    }
}

/// Minimum edge density per representation, at roughly half what the current
/// artwork measures. Edge density falls as the image grows — edges are a thin
/// band whose share of the area shrinks — so a single figure cannot serve every
/// size. The slack absorbs antialiasing differences between librsvg versions
/// without letting a blank or mushy icon through.
private let edgeFloor: [Int: Double] = [
    16: 0.18, 32: 0.12, 64: 0.07, 128: 0.035, 256: 0.018, 512: 0.015, 1024: 0.015,
]

@Test("The large representations are artwork, not a bare tile")
func iconIsArtwork() throws {
    // A smooth gradient tile with nothing drawn on it is a perfectly valid
    // .icns of the right size, so only local contrast distinguishes the two.
    for size in [256, 512, 1024] {
        let density = try raster(size).edgeDensity()
        #expect(
            density > edgeFloor[size]!,
            "\(size)px icon looks blank (edge density \(density))")
    }
}

@Test("The icon still reads at menu-bar size")
func iconSurvivesDownscaling() throws {
    // The failure this locks out: artwork gains fine detail, looks great in the
    // Dock, and dissolves into a smudge in the menu bar and Finder list views.
    for size in [16, 32, 64, 128] {
        let density = try raster(size).edgeDensity()
        #expect(
            density > edgeFloor[size]!,
            "\(size)px icon has almost no contrast left (edge density \(density))")
    }
}

@Test("The README image is the same artwork as the icon")
func readmeImageMatchesTheIcon() throws {
    // Both come from one rsvg-convert pass over the same SVG at 512px, so they
    // are pixel-identical — only the PNG container metadata differs, which is
    // why this compares pixels rather than bytes. The rot it locks out is a
    // README image left behind when the icon changes, or replaced by hand.
    let url =
        URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("docs/images/vbx-icon.png")
    let image = try #require(
        NSImage(contentsOf: url),
        "docs/images/vbx-icon.png is missing — run ./scripts/build-icon.sh")
    let rep = try #require(image.representations.first, "PNG carries no representation")
    let readme = try #require(Raster(rep), "README image did not rasterise")
    let icon = try raster(512)

    #expect(readme.width == 512 && readme.height == 512)
    #expect(readme.pixels == icon.pixels, "README image no longer matches the icon")
}

@Test("The icon leaves Apple's squircle margin transparent")
func iconRespectsTheIconGrid() throws {
    // macOS masks app icons to a squircle inset from the canvas. Artwork that
    // bleeds into the margin gets clipped, so the corners must stay empty.
    let large = try raster(1024)
    for (x, y) in [(4, 4), (1019, 4), (4, 1019), (1019, 1019)] {
        let (_, _, _, alpha) = large.rgba(x: x, y: y)
        #expect(alpha < 8, "canvas corner (\(x),\(y)) is not transparent")
    }
}
