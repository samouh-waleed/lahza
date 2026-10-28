import Foundation

/// A ``CensusSource`` over a synthetic library, for tests, previews and the DEBUG `-LZPhotos`
/// launch argument. It never touches PhotoKit.
///
/// The library follows a ``FakePhotoLibraryClient``: its access, and its count at that access
/// (12,480 photos and videos when full, 36 when limited). The same seed and count always give the
/// same library: camera outings with GPS, received photos at messaging sizes, screenshots, bursts,
/// old imports, a few duplicates and date anomalies, in realistic proportions. A small delay per
/// batch (`pace`) keeps progress visible; tests pass `.zero`.
public final class FakeCensusSource: CensusSource {
    public let name = CensusSourceName.sample

    private let library: FakePhotoLibraryClient
    private let seed: UInt64
    private let pace: Duration

    public init(library: FakePhotoLibraryClient, seed: UInt64 = 2026, pace: Duration = .milliseconds(20)) {
        self.library = library
        self.seed = seed
        self.pace = pace
    }

    @concurrent public func scanMetadata(progress: CensusProgressHandler) async throws -> CensusScan {
        let access = library.access
        guard access.canRead else { throw CensusError.noAccess }
        let synthetic = SyntheticLibrary(count: library.count(for: access), seed: seed)
        try await walk(synthetic.facts.count, batch: 250, progress: progress)
        // The synthetic names travel as the scan's handle, as the live source's fetch result does.
        return CensusScan(facts: synthetic.facts, access: access, extraBurstFrames: synthetic.extraBurstFrames, handle: synthetic.names)
    }

    @concurrent public func scanFilenames(of scan: CensusScan, progress: CensusProgressHandler) async throws -> [FilenameHint] {
        guard let names = scan.handle as? [String], names.count == scan.facts.count else { throw CensusError.mismatchedScan }
        try await walk(names.count, batch: 500, progress: progress)
        return names.map(FilenameHint.init(filename:))
    }

    @concurrent public func probeThumbnails(of scan: CensusScan, sampleSize: Int, progress: CensusProgressHandler) async throws -> ThumbnailProbe {
        var random = SeededGenerator(seed: seed &+ 1)
        let photos = scan.facts.indices.filter { scan.facts[$0].kind == .photo }
        let sample = photos.shuffled(using: &random).prefix(max(0, sampleSize))
        var tally = ThumbnailTally(requested: sampleSize)
        progress(CensusProgress(done: 0, total: sample.count))
        for (done, _) in sample.enumerated() {
            if done % 10 == 0 { try await rest() }
            // About nine in ten usable; the rest mostly iCloud only (an "Optimize Storage" library).
            let roll = random.unit()
            let outcome: ThumbnailOutcome = roll < 0.905 ? .usable : roll < 0.925 ? .tooSmall : roll < 0.99 ? .cloudOnly : .failed
            let milliseconds = outcome == .usable ? 6 + random.unit() * 22 : 1 + random.unit() * 4
            tally.add(outcome, duration: .milliseconds(milliseconds))
            progress(CensusProgress(done: done + 1, total: sample.count))
        }
        let total = sample.count == 0 ? Duration.zero : .milliseconds(Double(sample.count) * 9)
        return tally.result(total: total)
    }

    /// Reports progress over `total` items in batches, resting between them. Cancellation throws.
    private func walk(_ total: Int, batch: Int, progress: CensusProgressHandler) async throws {
        progress(CensusProgress(done: 0, total: total))
        var done = 0
        while done < total {
            try await rest()
            done = min(total, done + batch)
            progress(CensusProgress(done: done, total: total))
        }
    }

    private func rest() async throws {
        try Task.checkCancellation()
        if pace > .zero { try await Task.sleep(for: pace) } else { await Task.yield() }
    }
}

// MARK: Synthetic library

/// A deterministic library built from sessions, the way people take photos.
struct SyntheticLibrary {
    private(set) var facts: [AssetFacts] = []
    /// Synthetic filenames, parallel to `facts`.
    private(set) var names: [String] = []
    private(set) var extraBurstFrames = 0

    private var random: SeededGenerator
    private var imageNumber = 1_000

    /// Places sessions happen at (synthetic positions, a few km apart).
    private static let places = [
        Coordinate(latitude: 24.7136, longitude: 46.6753),
        Coordinate(latitude: 24.7743, longitude: 46.7386),
        Coordinate(latitude: 24.6877, longitude: 46.7219),
        Coordinate(latitude: 24.8120, longitude: 46.6280),
        Coordinate(latitude: 21.5433, longitude: 39.1728),
        Coordinate(latitude: 25.2048, longitude: 55.2708),
        Coordinate(latitude: 51.5072, longitude: -0.1276),
    ]
    /// 2016-01-01 to 2026-09-30, UTC.
    private static let start = Date(timeIntervalSince1970: 1_451_606_400)
    private static let end = Date(timeIntervalSince1970: 1_790_726_400)

    init(count: Int, seed: UInt64) {
        random = SeededGenerator(seed: seed)
        guard count > 0 else { return }
        while facts.count < count {
            let span = Self.end.timeIntervalSince(Self.start)
            // More photos in recent years.
            let when = Self.start.addingTimeInterval(span * pow(random.unit(), 0.55))
            let roll = random.unit()
            switch roll {
            case ..<0.62: addOuting(at: when)
            case ..<0.80: addReceived(at: when)
            case ..<0.93: addScreenCaptures(at: when)
            case ..<0.97: addBurst(at: when)
            default: addImport(at: when)
            }
        }
        facts.removeLast(facts.count - count)
        names.removeLast(names.count - count)
        addAnomalies()
    }

    // MARK: Sessions

    /// Photos and videos at one place, minutes apart: GPS in four of five outings.
    private mutating func addOuting(at start: Date) {
        let size = 1 + Int(-log(1 - random.unit()) * 7)
        let place = jitter(Self.places[Int(random.unit() * Double(Self.places.count))], metres: 2_000)
        let located = random.unit() < 0.82
        var time = start
        for _ in 0..<min(size, 60) {
            time = time.addingTimeInterval(10 + random.unit() * 360)
            var item: AssetFacts
            if random.unit() < 0.12 {
                item = video(at: time)
            } else {
                item = cameraPhoto(at: time)
            }
            if located && random.unit() < 0.97 {
                item.coordinate = jitter(place, metres: 150)
                item.horizontalAccuracy = accuracy()
            }
            append(item, name: cameraName(video: item.kind == .video))
            // Now and then the same photo twice (an edited copy, a re-save).
            if item.kind == .photo && random.unit() < 0.015 {
                append(item, name: cameraName(video: false))
            }
        }
    }

    /// Photos (and some videos) saved from chats: no GPS, messaging sizes, added as they arrive.
    private mutating func addReceived(at start: Date) {
        let size = 1 + Int(random.unit() * 5)
        var time = start
        for _ in 0..<size {
            time = time.addingTimeInterval(5 + random.unit() * 900)
            let added = time.addingTimeInterval(random.unit() * 3)
            if random.unit() < 0.15 {
                let item = AssetFacts(kind: .video, creationDate: time, modificationDate: added, addedDate: added,
                                      duration: 4 + random.unit() * 56, pixelWidth: 848, pixelHeight: 480)
                let name = random.unit() < 0.3 ? "VID-\(Self.compactDay(time))-WA\(String(format: "%04d", Int(random.unit() * 300))).mp4" : nextImageName("MP4")
                append(item, name: name)
                continue
            }
            let long: Int
            switch random.unit() {
            case ..<0.55: long = 1600
            case ..<0.75: long = 1280
            case ..<0.85: long = 2560
            case ..<0.90: long = 2048
            default: long = [1080, 1440, 1350, 960][Int(random.unit() * 4)]
            }
            let short = Int(Double(long) * (random.unit() < 0.7 ? 0.75 : 0.5625))
            let portrait = random.unit() < 0.5
            let item = AssetFacts(kind: .photo, format: .jpeg, creationDate: time, modificationDate: added, addedDate: added,
                                  pixelWidth: portrait ? short : long, pixelHeight: portrait ? long : short)
            let name: String
            switch random.unit() {
            case ..<0.20: name = "IMG-\(Self.compactDay(time))-WA\(String(format: "%04d", Int(random.unit() * 300))).jpg"
            case ..<0.25: name = "photo_\(Self.dashedDay(time))_\(String(format: "%02d-%02d-%02d", Int(random.unit() * 24), Int(random.unit() * 60), Int(random.unit() * 60))).jpg"
            case ..<0.28: name = "signal-\(Self.dashedDay(time))-\(String(format: "%06d", Int(random.unit() * 235_959))).jpg"
            default: name = nextImageName("JPG")  // iOS renames what apps save
            }
            append(item, name: name)
        }
    }

    /// Screenshots, and now and then a screen recording.
    private mutating func addScreenCaptures(at start: Date) {
        let size = 1 + Int(random.unit() * 3)
        var time = start
        for _ in 0..<size {
            time = time.addingTimeInterval(2 + random.unit() * 120)
            let added = time.addingTimeInterval(1)
            if random.unit() < 0.1 {
                let item = AssetFacts(kind: .video, subtypes: .screenRecording, creationDate: time, modificationDate: added, addedDate: added,
                                      duration: 8 + random.unit() * 90, pixelWidth: 886, pixelHeight: 1920)
                append(item, name: "RPReplay_Final\(Int(time.timeIntervalSince1970)).MP4")
            } else {
                let item = AssetFacts(kind: .photo, subtypes: .screenshot, format: .png, creationDate: time, modificationDate: added,
                                      addedDate: added, pixelWidth: 1179, pixelHeight: 2556)
                append(item, name: nextImageName("PNG"))
            }
        }
    }

    /// A burst: the representative, sometimes a frame or two picked out, the rest kept in the stack.
    private mutating func addBurst(at start: Date) {
        var item = cameraPhoto(at: start)
        item.subtypes = []
        item.hasBurstIdentifier = true
        item.representsBurst = true
        if random.unit() < 0.8 {
            item.coordinate = jitter(Self.places[0], metres: 3_000)
            item.horizontalAccuracy = accuracy()
        }
        append(item, name: cameraName(video: false))
        let picks = Int(random.unit() * 3)
        for _ in 0..<picks {
            item.representsBurst = false
            append(item, name: cameraName(video: false))
        }
        extraBurstFrames += 8 + Int(random.unit() * 22)
    }

    /// Old photos imported long after they were taken: scans and a digital camera's card.
    private mutating func addImport(at start: Date) {
        let size = 1 + Int(random.unit() * 15)
        let taken = Date(timeIntervalSince1970: 788_918_400 + random.unit() * 630_720_000)  // 1995–2014
        let added = start
        for index in 0..<size {
            let created = taken.addingTimeInterval(Double(index) * 40)
            let item = AssetFacts(kind: .photo, format: .jpeg, creationDate: created, modificationDate: added, addedDate: added,
                                  pixelWidth: 2048, pixelHeight: 1536)
            append(item, name: random.unit() < 0.5 ? "DSC_\(String(format: "%04d", 1 + Int(random.unit() * 9_998))).JPG" : "scan\(index + 1).jpg")
        }
    }

    /// A clock set wrong (dates in 2031), a few undated items, and favorites.
    private mutating func addAnomalies() {
        for index in facts.indices {
            if index % 1_499 == 1_000 { facts[index].creationDate = nil }
            if index % 2_003 == 1_500, facts[index].creationDate != nil {
                facts[index].creationDate = Date(timeIntervalSince1970: 1_930_000_000)
            }
            if random.unit() < 0.03 { facts[index].isFavorite = true }
        }
    }

    // MARK: Items

    private mutating func cameraPhoto(at time: Date) -> AssetFacts {
        var subtypes: AssetFacts.Subtypes = []
        if random.unit() < 0.55 { subtypes.insert(.livePhoto) }
        if random.unit() < 0.3 { subtypes.insert(.hdr) }
        if random.unit() < 0.05 { subtypes.insert(.depthEffect) }
        if random.unit() < 0.01 { subtypes.insert(.panorama) }
        let large = random.unit() < 0.4
        let portrait = random.unit() < 0.6
        let (long, short) = subtypes.contains(.panorama) ? (12_000, 3_000) : large ? (5_712, 4_284) : (4_032, 3_024)
        let added = time.addingTimeInterval(1 + random.unit() * 4)
        return AssetFacts(kind: .photo, subtypes: subtypes, format: random.unit() < 0.85 ? .heif : .jpeg, creationDate: time,
                          modificationDate: added, addedDate: added, pixelWidth: portrait ? short : long, pixelHeight: portrait ? long : short)
    }

    private mutating func video(at time: Date) -> AssetFacts {
        var subtypes: AssetFacts.Subtypes = []
        let roll = random.unit()
        if roll < 0.05 { subtypes.insert(.sloMo) } else if roll < 0.07 { subtypes.insert(.timeLapse) }
        let length: Double
        switch random.unit() {
        case ..<0.80: length = 3 + random.unit() * 57
        case ..<0.985: length = 60 + random.unit() * 540
        default: length = 600 + random.unit() * 2_400
        }
        let added = time.addingTimeInterval(length + 2)
        let uhd = random.unit() < 0.4
        return AssetFacts(kind: .video, subtypes: subtypes, creationDate: time, modificationDate: added, addedDate: added,
                          duration: length, pixelWidth: uhd ? 3_840 : 1_920, pixelHeight: uhd ? 2_160 : 1_080)
    }

    /// Mostly within 10 m, some within 100 m, a few coarse, a few unknown.
    private mutating func accuracy() -> Double? {
        switch random.unit() {
        case ..<0.6: 3 + random.unit() * 7
        case ..<0.88: 11 + random.unit() * 89
        case ..<0.97: 101 + random.unit() * 1_400
        default: nil
        }
    }

    private mutating func jitter(_ place: Coordinate, metres: Double) -> Coordinate {
        let degrees = metres / 111_000
        return Coordinate(latitude: place.latitude + (random.unit() * 2 - 1) * degrees,
                          longitude: place.longitude + (random.unit() * 2 - 1) * degrees)
    }

    private mutating func cameraName(video: Bool) -> String {
        nextImageName(video ? "MOV" : (random.unit() < 0.85 ? "HEIC" : "JPG"))
    }

    private mutating func nextImageName(_ ext: String) -> String {
        imageNumber = imageNumber == 9_999 ? 1 : imageNumber + 1
        return "IMG_\(String(format: "%04d", imageNumber)).\(ext)"
    }

    private mutating func append(_ item: AssetFacts, name: String) {
        facts.append(item)
        names.append(name)
    }

    private static func compactDay(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().dateSeparator(.omitted))
    }

    private static func dashedDay(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day())
    }
}

/// SplitMix64: a tiny seeded generator, so the synthetic library is the same on every run.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in 0..<1.
    mutating func unit() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }
}
