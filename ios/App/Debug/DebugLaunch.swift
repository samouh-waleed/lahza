import LZBilling
import LZEmbedding
import LZCore
import Foundation
import LZGeo
import LZIndex
import LZLibrary
import LZSearch

/// DEBUG launch arguments for review and screenshots. Release builds ignore them all.
///
///     xcrun simctl launch <device> com.waleedsamouh.lahza -LZRoute paywall -LZFakeStore 1
///
/// | argument                  | effect                                                          |
/// |---------------------------|-----------------------------------------------------------------|
/// | `-LZFreshInstall 1`       | in-memory storage, so onboarding shows and nothing is remembered |
/// | `-LZSkipOnboarding 1`     | in-memory storage with onboarding already done                   |
/// | `-LZFakeStore 1`          | a fake store with the sample $9.99 unlock (no RevenueCat; in-memory storage) |
/// | `-LZUnlocked 1\|0`        | the fake store, starting with the full library unlocked (search covers every year) or free (the last 12 months) |
/// | `-LZStoreKit 1`           | StoreKit directly, no RevenueCat (in-memory storage): the scheme's `Config/Lahza.storekit` when Xcode runs it |
/// | `-LZPhotos <access>`      | a fake photo library starting at that access (see below)         |
/// | `-LZSeed hero`            | the hero seed library without PhotoKit, fake Apple Maps (see below) |
/// | `-LZFakeMaps 1\|throttle\|offline` | the seed's fake Apple Maps over real PhotoKit, or throttled, or offline |
/// | `-LZIndex memory\|reset`  | an in-memory index, or delete the index on disk at launch        |
/// | `-LZIndexPace <ms>`       | sleeps per scan batch of 50, to watch (and kill) a scan          |
/// | `-LZNow <ISO 8601>`       | pins "now" (`2026-10-28T12:00:00+03:00`); time then runs on      |
/// | `-LZQuery "<text>"`       | selects Ask and searches once the index is ready (or after 20 s)  |
/// | `-LZModelDir <path>`      | the image and text model's folder (`make model`'s output); see ``ModelLocator`` |
/// | `-LZModel 0`              | no model, even when one is on the iPhone (tags only)             |
/// | `-LZLabAuto 1`            | Label lab or Description lab runs its checks by itself and prints the report (with `-LZRoute label-lab` or `description-lab`) |
/// | `-LZResultsLayout moments\|grid` | Ask's results start as moment cards or the grid (not remembered) |
/// | `-LZRoute <name>`         | opens a route once launch settles (see ``Route/debugName``)      |
/// | `-LZTheme light\|dark`    | forces an appearance                                             |
/// | `-LZReduceMotion 1`       | forces Reduce Motion                                             |
/// | `-LZReduceTransparency 1` | forces Reduce Transparency                                       |
///
/// `-LZPhotos` takes `notDetermined`, `limited`, `full`, `denied` or `restricted`. The fake library
/// never touches PhotoKit: its prompt answers full, it holds 12,480 photos and videos (36 when
/// limited), and Choose photos adds 12 more. The library census (Settings › Developer) then reads a
/// synthetic library of the same size, and the search index (in memory) reads it too.
///
/// `-LZSeed hero` serves the 561 items of ``SeedScenario/hero`` (seed artwork as thumbnails, seed clips as
/// videos) with the seed's fake Apple Maps at 600 requests a minute, into an in-memory index. It implies
/// `-LZPhotos full`; with `-LZPhotos limited` only the first 40 items are shared.
///
/// Search depends on the unlock: a free search covers the last 12 months, so review launches state it. `make screens`
/// and the review queries run with `-LZUnlocked 1` (the whole seed library); `-LZUnlocked 0` shows the free tier, and
/// buying from its "N more from earlier years" row unlocks in place:
///
///     xcrun simctl launch <device> com.waleedsamouh.lahza -LZSkipOnboarding 1 -LZSeed hero \
///         -LZNow 2026-10-28T12:00:00+03:00 -LZUnlocked 1 -LZQuery "Al-Nakheel Park"
struct DebugLaunch {
    var freshInstall = false
    var skipOnboarding = false
    var fakeStore = false
    /// `-LZUnlocked`: the fake store, already unlocked (true) or free (false).
    var unlocked: Bool?
    /// `-LZStoreKit`: purchases straight over StoreKit (``StoreKitPurchasesClient``).
    var storeKit = false
    /// `-LZPhotos`: the fake photo library's starting access.
    var photos: PhotoAccess?
    /// `-LZSeed`: a seed scenario's name.
    var seed: String?
    var fakeMaps: FakeMaps?
    var index: IndexMode?
    /// `-LZIndexPace`: milliseconds slept after each scan batch.
    var indexPace: Int?
    /// `-LZNow`.
    var now: Date?
    /// `-LZQuery`: a search to run at launch.
    var query: String?
    /// `-LZResultsLayout`: the layout Ask's results start in.
    var resultsLayout: SearchStore.ResultsLayout?
    /// `-LZModelDir`: the model folder to use.
    var modelDirectory: String?
    /// `-LZModel 0`: never use a model.
    var model: Bool?
    /// `-LZLabAuto 1`: the label lab runs its checks by itself.
    var labAuto = false
    var route: Route?
    var theme: AppearanceMode?
    var reduceMotion = false
    var reduceTransparency = false

    enum FakeMaps: String, Sendable {
        case on, throttle, offline
    }

    enum IndexMode: String, Sendable {
        case memory, reset
    }

    /// The seed library holds this many items before limited access shares only some.
    static let seedLimitedCount = 40

    static var current: DebugLaunch {
        #if DEBUG
        let defaults = UserDefaults.standard
        return parse { defaults.string(forKey: $0) }
        #else
        DebugLaunch()
        #endif
    }

    /// The arguments as `value(key)` reads them (launch arguments land in `UserDefaults`).
    static func parse(_ value: (String) -> String?) -> DebugLaunch {
        func flag(_ key: String) -> Bool { ["1", "yes", "true"].contains(value(key)?.lowercased() ?? "") }
        func choice(_ key: String) -> Bool? {
            switch value(key)?.lowercased() {
            case "1", "yes", "true": true
            case "0", "no", "false": false
            default: nil
            }
        }
        return DebugLaunch(
            freshInstall: flag("LZFreshInstall"),
            skipOnboarding: flag("LZSkipOnboarding"),
            fakeStore: flag("LZFakeStore"),
            unlocked: choice("LZUnlocked"),
            storeKit: flag("LZStoreKit"),
            photos: value("LZPhotos").flatMap { name in PhotoAccess.allCases.first { $0.rawValue.lowercased() == name.lowercased() } },
            seed: value("LZSeed")?.lowercased(),
            fakeMaps: value("LZFakeMaps").flatMap { flag("LZFakeMaps") ? .on : FakeMaps(rawValue: $0.lowercased()) },
            index: value("LZIndex").flatMap { IndexMode(rawValue: $0.lowercased()) },
            indexPace: value("LZIndexPace").flatMap(Int.init).map { max(0, $0) },
            now: value("LZNow").flatMap(Self.date),
            query: value("LZQuery").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 },
            resultsLayout: value("LZResultsLayout").flatMap { SearchStore.ResultsLayout(rawValue: $0.lowercased()) },
            modelDirectory: value("LZModelDir").flatMap { $0.isEmpty ? nil : $0 },
            model: choice("LZModel"),
            labAuto: flag("LZLabAuto"),
            route: value("LZRoute").flatMap(Route.init(debugName:)),
            theme: value("LZTheme").flatMap(AppearanceMode.init(rawValue:)),
            reduceMotion: flag("LZReduceMotion"),
            reduceTransparency: flag("LZReduceTransparency")
        )
    }

    func apply(to dependencies: inout AppDependencies) {
        var labels: [String] = []
        if freshInstall || skipOnboarding {
            let kv = InMemoryKeyValueStore([:])
            if skipOnboarding { AppPreferences(kv: kv).markOnboardingCompleted(at: Date()) }
            dependencies.kv = kv
            labels.append(freshInstall ? "fresh-install" : "skip-onboarding")
        }
        let fakeStore = fakeStore || unlocked != nil
        if fakeStore || storeKit {
            // Test purchases never touch the real defaults (the cached unlock): run on in-memory
            // storage, carrying over only whether onboarding was done.
            if !(freshInstall || skipOnboarding) {
                let kv = InMemoryKeyValueStore([:])
                if AppPreferences(kv: dependencies.kv).onboardingCompleted { AppPreferences(kv: kv).markOnboardingCompleted(at: Date()) }
                dependencies.kv = kv
            }
            // A Test Store key, so the paywall says "Test purchases only".
            dependencies.billingEnvironment = BillingEnvironment(apiKey: "test_local_store", configuration: .debug)
        }
        if let unlocked {
            dependencies.purchases = FakePurchasesClient(unlocked: unlocked)
            // The first screen already knows, before the fake store answers.
            dependencies.kv.setString(unlocked ? EntitlementStore.Status.unlocked.rawValue : EntitlementStore.Status.free.rawValue,
                                      forKey: KVKey.device(KVSuffix.entitlementCache))
            labels.append(unlocked ? "unlocked" : "free")
        } else if fakeStore {
            dependencies.purchases = FakePurchasesClient()
            labels.append("fake-store")
        } else if storeKit {
            dependencies.purchases = StoreKitPurchasesClient()
            labels.append("storekit")
        }
        if let photos, seed == nil {
            let library = FakePhotoLibraryClient(access: photos, answer: .full)
            use(library, in: &dependencies)
            dependencies.libraryReader = FakeLibraryReader(.synthetic(library))
            // Placeholder pictures: nothing for Vision to see.
            dependencies.visual = .off
            labels.append("photos-\(photos.rawValue)")
        }
        #if DEBUG
        if let seed, let name = SeedScenario.Name(rawValue: seed) {
            let scenario = SeedScenario.named(name)
            let library = FakePhotoLibraryClient(access: photos ?? .full, answer: .full,
                                                 counts: [.full: scenario.items.count, .limited: Self.seedLimitedCount])
            use(library, in: &dependencies)
            dependencies.libraryReader = FakeLibraryReader(.seed(name), following: library)
            dependencies.visual = .seed
            dependencies.maps = SeedMaps.client(latency: .milliseconds(150))
            dependencies.mapsPerMinute = 600
            dependencies.network = FakeNetworkStatus(reachable: true)
            labels.append("seed-\(name.rawValue)" + (photos.map { "-\($0.rawValue)" } ?? ""))
        }
        if let fakeMaps {
            let maps = SeedMaps.client(latency: .milliseconds(150))
            switch fakeMaps {
            case .on: break
            case .throttle: maps.setFailure(.throttled)
            case .offline:
                maps.setFailure(.offline)
                dependencies.network = FakeNetworkStatus(reachable: false)
            }
            dependencies.maps = maps
            labels.append("maps-\(fakeMaps.rawValue)")
        }
        #endif
        switch index {
        case .memory: dependencies.indexLocation = .inMemory
        case .reset: dependencies.resetIndexOnLaunch = true
        case nil: break
        }
        if let index { labels.append("index-\(index.rawValue)") }
        if let indexPace {
            dependencies.indexSettings.pacePerBatch = .milliseconds(indexPace)
            // Small batches, so a library of a few hundred items still takes a while to read.
            dependencies.indexSettings.batchSize = 50
            labels.append("pace-\(indexPace)")
        }
        if let now {
            dependencies.clock = OffsetClock(pinnedNow: now)
            labels.append("now")
        }
        #if DEBUG
        if let query {
            dependencies.queryAtLaunch = query
            labels.append("query")
        }
        // The image model goes with Vision only (the seed's and the fakes' pictures are drawn).
        if dependencies.visual == .vision, model != false, let folder = ModelLocator.folder(override: modelDirectory) {
            dependencies.embedders = ModelFolderEmbedderSource(folder: folder)
            let text = ModelFolderTextEncoder(folder: folder)
            if text.model != nil { dependencies.textEncoder = text }
            labels.append("model")
        }
        if dependencies.visual != .vision { dependencies.albums = FakeAlbumSource() }
        if labAuto {
            dependencies.labelLabAuto = true
            labels.append("lab-auto")
        }
        #endif
        if let resultsLayout {
            dependencies.resultsLayout = resultsLayout
            labels.append("layout-\(resultsLayout.rawValue)")
        }
        if let route { dependencies.initialRoute = route }
        if let theme { dependencies.appearanceOverride = theme }
        if !labels.isEmpty { dependencies.label = "debug:" + labels.joined(separator: "+") }
    }

    /// A fake photo library for the app: the access store, the limited picker (the system picker needs real
    /// PhotoKit access, so the fake "picks" a few more photos instead), the census, fake thumbnails and an
    /// in-memory index, so nothing fake is ever written over the real index.
    private func use(_ library: FakePhotoLibraryClient, in dependencies: inout AppDependencies) {
        dependencies.photoLibrary = library
        dependencies.presentLimitedLibraryPicker = {
            library.setCount(library.count(for: .limited) + 12, for: .limited)
            library.emitChange()
        }
        #if DEBUG
        dependencies.censusSource = FakeCensusSource(library: library)
        #endif
        dependencies.images = FakeAssetImageProvider()
        dependencies.videos = FakeVideoLoader()
        dependencies.indexLocation = .inMemory
    }

    /// An ISO 8601 date-time with a zone, with or without fractional seconds.
    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
