// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Betterlink",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "BetterlinkCore", targets: ["BetterlinkCore"]),
        .executable(name: "Betterlink", targets: ["Betterlink"]),
    ],
    dependencies: [
        // Auto-update. Pinned exactly; the release script re-signs it with
        // betterlink's Developer ID.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
    ],
    targets: [
        // Everything that decides where a link goes. No AppKit, so it is unit-testable.
        .target(
            name: "BetterlinkCore",
            linkerSettings: [.linkedFramework("JavaScriptCore")],
        ),
        .executableTarget(
            name: "Betterlink",
            dependencies: ["BetterlinkCore", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("SwiftUI")],
        ),
        .testTarget(
            name: "BetterlinkCoreTests",
            dependencies: ["BetterlinkCore"],
            resources: [.copy("Fixtures")],
        ),
    ],
    swiftLanguageModes: [.v5],
)
