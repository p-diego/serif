// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Serif",
    platforms: [.macOS(.v26)],
    dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.20.0")],
    targets: [
        .target(name: "SerifCore"),
        .target(name: "SerifEngine", dependencies: ["SerifCore", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .executableTarget(name: "serifd", dependencies: ["SerifEngine"]),
        .executableTarget(name: "serif-hook", dependencies: ["SerifCore"]),
        .executableTarget(name: "fake-claude", dependencies: ["SerifCore"]),
        .executableTarget(name: "fake-codex", dependencies: ["SerifCore"]),
        .executableTarget(name: "serifctl", dependencies: ["SerifCore"]),    // dev-only, not in the app bundle
        .executableTarget(name: "Serif", dependencies: ["SerifCore", .product(name: "SwiftTerm", package: "SwiftTerm")],
                      exclude: ["Resources"]),    // copied into the bundle by the packaging step
        .testTarget(name: "SerifCoreTests", dependencies: ["SerifCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "SerifEngineTests", dependencies: ["SerifEngine", "serif-hook", "fake-claude", "fake-codex"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v5]
)
