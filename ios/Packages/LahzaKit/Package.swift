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
        .library(name: "LZGeo", targets: ["LZGeo"]),
        .library(name: "LZIndex", targets: ["LZIndex"]),
        .executable(name: "lz-gazetteer", targets: ["LZGazetteerTool"]),
        .executable(name: "lz-seed", targets: ["LZSeedTool"]),
    ],
    dependencies: [
        .package(url: "https://github.com/RevenueCat/purchases-ios-spm.git", from: "5.91.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
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
        // Foundation-only geography and time: Coordinate, GeoHash, LocalTime, MomentSegmenter, PlaceNames,
        // CountryNames, the offline GeoNames gazetteer (format, reader, writer), PlaceCategory radii and the Apple
        // Maps client protocol (fake, and the live MapKit adapter on iOS).
        .target(name: "LZGeo", resources: [.copy("Resources/cities15000.lzgz")]),
        // Photo library access: the PhotoKit client (live and fake), the access store, the fetch rules, the library
        // reader and image provider (live and fake); the library census for Phase 0 spike S2, whose screen exists only
        // in DEBUG builds; and the DEBUG seed scenario (library, artwork, fake Apple Maps, import capabilities).
        .target(name: "LZLibrary", dependencies: ["LZCore", "LZGeo"]),
        // The search index: GRDB storage (one SQLite file, a rebuildable cache), library sync and read models. GRDB
        // stays inside this module (`internal import`), so the app and later modules never see it.
        .target(name: "LZIndex", dependencies: ["LZCore", "LZGeo", "LZLibrary", .product(name: "GRDB", package: "GRDB.swift")]),
        // macOS host tools, never linked into the app: the gazetteer resource builder (`make gazetteer`) and the
        // seed library renderer (`make seed-photos`, debug builds only).
        .executableTarget(name: "LZGazetteerTool", dependencies: ["LZGeo"]),
        .executableTarget(name: "LZSeedTool", dependencies: ["LZGeo", "LZLibrary"]),

        .testTarget(name: "LZCoreTests", dependencies: ["LZCore"]),
        .testTarget(name: "LZBillingTests", dependencies: ["LZBilling"]),
        .testTarget(name: "LZDesignTests", dependencies: ["LZDesign"]),
        .testTarget(name: "LZLibraryTests", dependencies: ["LZLibrary", "LZGeo"]),
        .testTarget(name: "LZGeoTests", dependencies: ["LZGeo"]),
        .testTarget(name: "LZIndexTests", dependencies: ["LZIndex", "LZLibrary", "LZGeo", "LZCore", .product(name: "GRDB", package: "GRDB.swift")]),
    ]
)
