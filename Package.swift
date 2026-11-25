// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Betterlink",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "BetterlinkCore", targets: ["BetterlinkCore"]),
        .executable(name: "Betterlink", targets: ["Betterlink"]),
        .executable(name: "betterlink-tabhost", targets: ["betterlink-tabhost"]),
        .executable(name: "betterlink-tabs", targets: ["betterlink-tabs"]),
    ],
    dependencies: [
        // Auto-update. Pinned exactly, and to a commit by Package.resolved
        // (committed; `make build` refuses any other). The release script
        // re-signs it with betterlink's Developer ID.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        // Everything that decides where a link goes. No AppKit, so it is unit-testable.
        .target(
            name: "BetterlinkCore",
            linkerSettings: [.linkedFramework("JavaScriptCore")],
        ),
        // Tabs (preview): live two-way sync with the browser's tabs. Protocol,
        // per-browser tab store and socket discovery. Foundation only, no AppKit.
        .target(name: "TabSyncCore"),
        // The native messaging host a browser launches for the Tabs extension.
        // Ships in Contents/Helpers; bridges the browser's stdio to a local socket.
        .executableTarget(name: "betterlink-tabhost", dependencies: ["TabSyncCore"]),
        // Terminal view of the same sync (debugging, and the e2e test's app side).
        .executableTarget(name: "betterlink-tabs", dependencies: ["TabSyncCore"]),
        .executableTarget(
            name: "Betterlink",
            dependencies: ["BetterlinkCore", "TabSyncCore", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("SwiftUI")],
        ),
        .testTarget(
            name: "BetterlinkCoreTests",
            dependencies: ["BetterlinkCore"],
            resources: [.copy("Fixtures")],
        ),
        // The app's own views, where a layout promise needs a test.
        .testTarget(name: "BetterlinkTests", dependencies: ["Betterlink", "BetterlinkCore", "TabSyncCore"]),
        .testTarget(name: "TabSyncCoreTests", dependencies: ["TabSyncCore"]),
    ],
    swiftLanguageModes: [.v5],
)
