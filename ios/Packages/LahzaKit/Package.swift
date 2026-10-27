// swift-tools-version: 6.2
// The engines behind the native Lahza app. Logic targets are platform-neutral so `swift test` runs them on
// the Mac host; UI and iOS-only code is guarded with `#if os(iOS)` or `#if canImport(...)` and
// verified by `xcodebuild` on the simulator.
import PackageDescription

let package = Package(
    name: "LahzaKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "DDCore", targets: ["DDCore"]),
        .library(name: "DDBilling", targets: ["DDBilling"]),
        .library(name: "DDDesign", targets: ["DDDesign"]),
    ],
    dependencies: [
        .package(url: "https://github.com/RevenueCat/purchases-ios-spm.git", from: "5.91.0"),
    ],
    targets: [
        // Foundation-level helpers shared by everything (brand, environment, kv, clock, log).
        .target(name: "DDCore"),
        // RevenueCat purchases, the on-device entitlement and the paywall model.
        .target(name: "DDBilling", dependencies: ["DDCore", .product(name: "RevenueCat", package: "purchases-ios-spm")]),
        // Design system: tokens, type, controls, motion, haptics.
        .target(
            name: "DDDesign",
            dependencies: ["DDCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),

        .testTarget(name: "DDCoreTests", dependencies: ["DDCore"]),
        .testTarget(name: "DDBillingTests", dependencies: ["DDBilling"]),
        .testTarget(name: "DDDesignTests", dependencies: ["DDDesign"]),
    ]
)
