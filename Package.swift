// swift-tools-version: 6.0
import PackageDescription
import Foundation

// The Go engine archive is produced by Scripts/build-engine.sh into
// Engine/build. Resolving an absolute path from #filePath keeps the linker
// flags correct regardless of the directory the build is invoked from.
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let engineBuildDir = "\(packageRoot)/Engine/build"

// Frameworks the Go runtime and modernc.org/sqlite need on darwin.
let engineLinkerSettings: [LinkerSetting] = [
    .unsafeFlags(["-L\(engineBuildDir)"]),
    .linkedLibrary("bvxengine"),
    .linkedLibrary("resolv"),
    .linkedFramework("CoreFoundation"),
    .linkedFramework("Security"),
]

let package = Package(
    name: "bvx",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "bvx", targets: ["bvx"]),
        .executable(name: "bvx-cli", targets: ["bvx-cli"]),
        .library(name: "BVXCore", targets: ["BVXCore"]),
        .library(name: "BVXEngine", targets: ["BVXEngine"]),
    ],
    targets: [
        // C module exposing the Go archive's generated header.
        .target(
            name: "CBVXEngine",
            linkerSettings: engineLinkerSettings
        ),

        // Value types and pure logic. No engine dependency, so it stays
        // testable without linking the archive.
        .target(name: "BVXCore"),

        // async/await facade over the C ABI.
        .target(
            name: "BVXEngine",
            dependencies: ["CBVXEngine", "BVXCore"]
        ),

        // Application state, split out of the executable so it can be tested
        // headlessly — an executable target cannot be imported by tests.
        .target(
            name: "BVXAppCore",
            dependencies: ["BVXCore", "BVXEngine"]
        ),

        .executableTarget(
            name: "bvx",
            dependencies: ["BVXCore", "BVXEngine", "BVXAppCore"]
        ),

        .executableTarget(
            name: "bvx-cli",
            dependencies: ["BVXCore", "BVXEngine"]
        ),

        .testTarget(name: "BVXCoreTests", dependencies: ["BVXCore"]),
        .testTarget(name: "BVXEngineTests", dependencies: ["BVXEngine", "BVXCore"]),
        .testTarget(name: "BVXAppCoreTests", dependencies: ["BVXAppCore", "BVXCore"]),
    ],
    swiftLanguageModes: [.v5]
)
