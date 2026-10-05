// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexLens",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CodexLens", targets: ["CodexLens"]), .executable(name: "lens-inspect", targets: ["LensInspect"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "LensCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "CodexLens", dependencies: ["LensCore"]),
        .executableTarget(name: "LensInspect", dependencies: ["LensCore"]),
        .testTarget(name: "LensCoreTests", dependencies: ["LensCore"])
    ],
    swiftLanguageModes: [.v5]
)
