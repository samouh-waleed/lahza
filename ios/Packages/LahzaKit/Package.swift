// swift-tools-version: 6.2
// The engines behind the native Lahza app. Logic targets are platform-neutral so `swift test` runs them on
// the Mac host; UI and iOS-only code is guarded with `#if os(iOS)` or `#if canImport(...)` and
// verified by `xcodebuild` on the simulator.
import PackageDescription

let package = Package(
    name: "LahzaKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "LZCore", targets: ["LZCore"]),
        .library(name: "LZBilling", targets: ["LZBilling"]),
        .library(name: "LZDesign", targets: ["LZDesign"]),
        .library(name: "LZLibrary", targets: ["LZLibrary"]),
    ],
    dependencies: [
        .package(url: "https://github.com/RevenueCat/purchases-ios-spm.git", from: "5.91.0"),
    ],
    targets: [
        // Foundation-level helpers shared by everything (brand, environment, kv, clock, log).
        .target(name: "LZCore"),
        // RevenueCat purchases, the on-device entitlement and the paywall model.
        .target(name: "LZBilling", dependencies: ["LZCore", .product(name: "RevenueCat", package: "purchases-ios-spm")]),
        // Design system: tokens, type, controls, motion, haptics.
        .target(
            name: "LZDesign",
            dependencies: ["LZCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        // Photo library access: the PhotoKit client (live and fake) and the access store; the library census for
        // Phase 0 spike S2 (facts, summariser, sources live and fake, runner), whose screen exists only in DEBUG builds.
        .target(name: "LZLibrary", dependencies: ["LZCore"]),

        .testTarget(name: "LZCoreTests", dependencies: ["LZCore"]),
        .testTarget(name: "LZBillingTests", dependencies: ["LZBilling"]),
        .testTarget(name: "LZDesignTests", dependencies: ["LZDesign"]),
        .testTarget(name: "LZLibraryTests", dependencies: ["LZLibrary"]),
    ]
)
