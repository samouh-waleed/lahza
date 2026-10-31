import Darwin
import Foundation
import LZCore
import LZEmbedding
internal import GRDB

/// P1a and P1b's tunables (placeholders to tune on the iPhone).
public struct VisualPolicy: Sendable {
    /// Photos per transaction.
    public var batchSize: Int
    /// Photos tagged at the same time (image loading overlaps Vision).
    public var concurrency: Int
    /// Search sees new tags at a checkpoint (an index version), at most this often, and when the queue stops.
    public var checkpointInterval: Duration
    /// Photos only in iCloud are looked at again after this long.
    public var cloudRetry: TimeInterval
    /// The window tagged first, newest first (the free search's months).
    public var recentWindow: TimeInterval
    /// A hot iPhone (`.serious`): wait this long before the next batch.
    public var thermalPause: Duration
    /// Photos embedded before any other (``ReferenceSample``).
    public var referenceSize: Int

    public init(batchSize: Int = 32, concurrency: Int = 2, checkpointInterval: Duration = .seconds(3), cloudRetry: TimeInterval = 6 * 3_600,
                recentWindow: TimeInterval = 365 * 86_400, thermalPause: Duration = .seconds(30), referenceSize: Int = ReferenceSample.size) {
        self.batchSize = batchSize
        self.concurrency = concurrency
        self.checkpointInterval = checkpointInterval
        self.cloudRetry = cloudRetry
        self.recentWindow = recentWindow
        self.thermalPause = thermalPause
        self.referenceSize = referenceSize
    }

    public static let `default` = VisualPolicy()
}

/// How far the Vision and embedding passes have got (Settings, the label lab, the coverage line).
public struct VisualProgress: Sendable, Hashable {
    public enum State: Sendable, Hashable {
        case idle, running, backgrounded, done
        /// Waiting for a hot iPhone to cool down (`.serious`).
        case cooling
        /// Stopped for a critically hot iPhone; it starts again when Lahza next becomes active.
        case tooHot
    }

    /// Photos and videos tagged.
    public var checked: Int
    /// Only in iCloud: not checked yet.
    public var pendingCloud: Int
    /// In the index.
    public var total: Int
    public var state: State
    /// Photos handled (tagged, embedded or both) per second over the latest run (nil before one has handled any).
    public var photosPerSecond: Double?
    /// The app's memory footprint at the latest checkpoint, in bytes.
    public var footprint: UInt64?
    /// Photos and videos with a vector; nil without an image model on this iPhone.
    public var embedded: Int?
    /// Vectors made per second over the latest run (nil before one has made any).
    public var vectorsPerSecond: Double?
    /// The highest footprint the queue has seen, in bytes.
    public var peakFootprint: UInt64?
    /// The hottest the iPhone got while the queue ran.
    public var peakThermal: ProcessInfo.ThermalState
    /// How long the image model took to load, the latest time.
    public var modelLoad: Duration?

    public init(checked: Int = 0, pendingCloud: Int = 0, total: Int = 0, state: State = .idle, photosPerSecond: Double? = nil, footprint: UInt64? = nil,
                embedded: Int? = nil, vectorsPerSecond: Double? = nil, peakFootprint: UInt64? = nil, peakThermal: ProcessInfo.ThermalState = .nominal,
                modelLoad: Duration? = nil) {
        self.checked = checked
        self.pendingCloud = pendingCloud
        self.total = total
        self.state = state
        self.photosPerSecond = photosPerSecond
        self.footprint = footprint
        self.embedded = embedded
        self.vectorsPerSecond = vectorsPerSecond
        self.peakFootprint = peakFootprint
        self.peakThermal = peakThermal
        self.modelLoad = modelLoad
    }
}

/// P1a and P1b: tags every photo with Vision and, once an image model is on the iPhone, embeds it into the vector file,
/// both from one image (content search L2 and L3). Like ``PlaceNameQueue`` it is its own actor, writes only its own
/// tables (`visual_label`, `asset_label`, `asset_visual`) and the vector file, runs only while Lahza is open, and asks
/// the indexer to publish the new index version at checkpoints (`notify`), so search sees the tags as they come.
///
/// Order: with a model, the reference sample first (``ReferenceSample``: search calibrates against it); then the last
/// 12 months newest first, then everything older, newest first. A photo is tagged again after a content edit
/// (`adjusted_utc`), a ``VisualPass`` bump, or a changed Vision tag list (an iOS update); one only in iCloud after
/// ``VisualPolicy/cloudRetry``. Vectors are separate (``EmbedPass``): turning the model on fills only the photos without
/// one, an edit makes it again, and the foreground makes again what the CPU made in the background. Vectors of photos no
/// longer in the index are removed at the start of a run and at checkpoints. It pauses while the iPhone is seriously
/// hot and stops when critically hot. ``run()`` returns when nothing is left to do now, or when its task is cancelled,
/// and lets go of the model.
public actor VisualQueue {
    private let database: IndexDatabase
    private let analyzer: any VisualAnalyzer
    private let embedders: (any ImageEmbedderSource)?
    private let vectors: VectorIndex?
    private let clock: any AppClock
    private let notify: @Sendable () async -> Void
    private let policy: VisualPolicy
    private let broadcaster: Broadcaster<VisualProgress>
    private let log = Log("visual")

    private var labelIDs: [String: Int64] = [:]
    private var counts = (checked: 0, pendingCloud: 0, total: 0, embedded: 0)
    private var rate: Double?
    private var vectorRate: Double?
    private var peakFootprint: UInt64?
    private var peakThermal = ProcessInfo.ThermalState.nominal
    private var modelLoad: Duration?
    /// Where vectors are made (``setMode(_:)``).
    private var mode = ComputeMode.foreground

    /// Candidates read at a time.
    static let window = 512

    /// `embedders` and `vectors`: the image model on this iPhone and the index's vector file (no vectors without both).
    public init(database: IndexDatabase, analyzer: any VisualAnalyzer, embedders: (any ImageEmbedderSource)? = nil, vectors: VectorIndex? = nil,
                clock: any AppClock, notify: @escaping @Sendable () async -> Void, policy: VisualPolicy = .default) {
        self.database = database
        self.analyzer = analyzer
        self.embedders = embedders
        self.vectors = vectors
        self.clock = clock
        self.notify = notify
        self.policy = policy
        broadcaster = Broadcaster(VisualProgress())
    }

    /// Checked photos and what the queue is doing: a fresh stream per subscriber, newest only.
    public nonisolated var progress: AsyncStream<VisualProgress> { broadcaster.stream() }

    /// Makes vectors in the foreground (Neural Engine) or the background (CPU only) from the next batch on.
    public func setMode(_ mode: ComputeMode) {
        self.mode = mode
    }

    /// The model this queue embeds with: nil without one, or without a vector file.
    private var model: EmbeddingModel? { vectors == nil ? nil : embedders?.model }

    // MARK: Run

    /// One run's vector file and model. Each run has its own: a cancelled run that finishes after the next one started
    /// never touches the next one's.
    private final class EmbedRun {
        /// The vector file, open while the model is on the iPhone.
        let store: VectorStore?
        /// Embedded before any other photo.
        let reference: Set<Int64>
        /// The loaded model, once a photo needed a vector.
        var embedder: (embedder: any ImageEmbedder, mode: ComputeMode)?
        /// The model failed to load: no more vectors this run.
        var failed = false

        init(store: VectorStore? = nil, reference: Set<Int64> = []) {
            self.store = store
            self.reference = reference
        }

        /// Vectors are made this run.
        var embeds: Bool { store != nil && !failed }
    }

    private struct Candidate: Sendable {
        var asset: VisualAsset
        var adjusted: Int64?
        /// Its tags are due.
        var tags: Bool
        /// Its vector is due.
        var vector: Bool
        /// Edited since its tags (and vector) were made.
        var edited: Bool
        /// The vector it has (`embed_version`, `embed_units`), kept when only its tags are made again.
        var embedVersion: Int?
        var embedUnits: Int?
    }

    /// Tags and embeds photos until none is due or the task is cancelled. The caller owns the task.
    public func run() async {
        let current: EmbedRun
        do {
            let prepared = try await prepare()
            current = prepared.run
            if prepared.changed { await notify() }
        } catch {
            log.error("Vision pass setup failed: \(IndexDatabase.code(of: error))", privacy: .public)
            return
        }
        await refreshCounts()
        var handled = Set<Int64>()
        var done = 0, embedded = 0
        var activeSeconds = 0.0
        var lastCheckpoint = ContinuousClock.now
        var unpublished = false
        loop: while !Task.isCancelled {
            let thermal = ProcessInfo.processInfo.thermalState
            if thermal.rawValue > peakThermal.rawValue { peakThermal = thermal }
            if thermal == .critical {
                log.notice("Vision pass stopped: the iPhone is critically hot", privacy: .public)
                publish(.tooHot)
                break
            }
            if thermal == .serious {
                publish(.cooling)
                do { try await clock.sleep(for: policy.thermalPause) } catch { break }
                continue
            }
            let candidates: [Candidate]
            do {
                candidates = try await next(excluding: handled, current)
            } catch {
                log.error("Vision pass read failed: \(IndexDatabase.code(of: error))", privacy: .public)
                break
            }
            guard !candidates.isEmpty else { break }
            publish(.running)
            for start in stride(from: 0, to: candidates.count, by: policy.batchSize) {
                let batch = Array(candidates[start..<min(candidates.count, start + policy.batchSize)])
                let started = ContinuousClock.now
                if batch.contains(where: \.vector) { await loadEmbedder(current) }
                let results = await analyze(batch, embedder: current.embedder?.embedder)
                for candidate in batch { handled.insert(candidate.asset.id) }
                do {
                    let written = try await write(results, current)
                    if written.rows { unpublished = true }
                    embedded += written.vectors
                } catch {
                    log.error("Vision pass write failed: \(IndexDatabase.code(of: error))", privacy: .public)
                    break loop
                }
                done += results.count
                activeSeconds += (ContinuousClock.now - started).seconds
                rate = activeSeconds > 0 ? Double(done) / activeSeconds : nil
                vectorRate = activeSeconds > 0 && embedded > 0 ? Double(embedded) / activeSeconds : vectorRate
                if unpublished, ContinuousClock.now - lastCheckpoint >= policy.checkpointInterval {
                    await checkpoint(current)
                    unpublished = false
                    lastCheckpoint = ContinuousClock.now
                }
                if Task.isCancelled || ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue { continue loop }
            }
        }
        if unpublished { await checkpoint(current) }
        if done > 0 {
            log.info("Vision pass: \(done) done at \(String(format: "%.1f", rate ?? 0))/s, \(embedded) vectors, \(counts.checked) of \(counts.total) checked, "
                     + "\(counts.pendingCloud) only in iCloud", privacy: .public)
        }
        if current.embedder != nil {
            current.embedder = nil
            await embedders?.release()
        }
        if !Task.isCancelled, broadcaster.latest.state != .tooHot { publish(.done) }
    }

    /// Records the tag list and the pass version, and opens the vector file when the model is on the iPhone; returns
    /// whether search must be told (the pass just started, or every photo is due again), and the run's vector file.
    private func prepare() async throws -> (changed: Bool, run: EmbedRun) {
        let labels = await analyzer.supportedLabels()
        let hash = Int64(bitPattern: Self.hash(labels))
        let ids = try await database.write { db -> (ids: [String: Int64], changed: Bool) in
            for name in labels { try db.execute(sql: "INSERT OR IGNORE INTO visual_label (name) VALUES (?)", arguments: [name]) }
            var ids: [String: Int64] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, name FROM visual_label") { ids[row["name"]] = row["id"] }
            let version = try Meta.int(db, .visualVersion)
            let previousHash = try Meta.int(db, .visualLabelsHash)
            var changed = false
            if version != Int64(VisualPass.version) {
                try Meta.set(db, .visualVersion, VisualPass.version)
                changed = true
            }
            if previousHash != hash {
                // A new tag list (an iOS update): every photo is due again.
                if previousHash != nil { try db.execute(sql: "UPDATE asset_visual SET labels_version = 0") }
                try Meta.set(db, .visualLabelsHash, hash)
                changed = true
            }
            if changed { try Meta.bumpVersion(db) }
            return (ids, changed)
        }
        labelIDs = ids.ids
        var run = EmbedRun()
        if let model, let vectors {
            do {
                let opened = try await vectors.store(modelID: model.id, dimension: model.dimension)
                try await reconcile(opened, lost: true)
                let reference = ReferenceSample.pick(try await database.read { db in try Int64.fetchAll(db, sql: "SELECT id FROM asset") },
                                                     count: policy.referenceSize)
                run = EmbedRun(store: opened, reference: reference)
            } catch {
                log.error("Vector file unavailable: \(IndexDatabase.code(of: error))", privacy: .public)
            }
        }
        return (ids.changed, run)
    }

    /// FNV-1a over the tag names.
    static func hash(_ labels: [String]) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in labels.joined(separator: "\n").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0100_0000_01b3
        }
        return hash
    }

    /// The vector file and the index agree: vectors of photos no longer in the index go (deleted, swept), and with
    /// `lost`, photos the index says have a vector the file doesn't hold (a new file, another model) are due again.
    private func reconcile(_ store: VectorStore, lost: Bool) async throws {
        let stored = Set(await store.assetIDs)
        let (assets, recorded) = try await database.read { db in
            (Set(try Int64.fetchAll(db, sql: "SELECT id FROM asset")),
             lost ? Set(try Int64.fetchAll(db, sql: "SELECT asset_id FROM asset_visual WHERE embed_units IN (?, ?)",
                                           arguments: [EmbedUnits.all.rawValue, EmbedUnits.cpu.rawValue])) : [])
        }
        let gone = stored.subtracting(assets)
        if !gone.isEmpty { try await store.remove(gone) }
        let missing = Array(recorded.subtracting(stored))
        guard !missing.isEmpty else { return }
        try await database.write { db in
            for start in stride(from: 0, to: missing.count, by: 500) {
                let chunk = Array(missing[start..<min(missing.count, start + 500)])
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                try db.execute(sql: "UPDATE asset_visual SET embed_version = NULL, embed_units = NULL WHERE asset_id IN (\(marks))",
                               arguments: StatementArguments(chunk))
            }
        }
    }

    /// Loads the model for the current mode when the run first needs a vector (or the mode changed).
    private func loadEmbedder(_ run: EmbedRun) async {
        guard run.store != nil, !run.failed, run.embedder?.mode != mode, let embedders else { return }
        do {
            run.embedder = (try await embedders.embedder(mode), mode)
            modelLoad = await embedders.lastLoad()
        } catch {
            run.failed = true
            log.error("Image model failed to load: \(String(describing: error))", privacy: .public)
        }
    }

    // MARK: Picking

    /// The next photos due: with a model, the reference sample first; then the last 12 months newest first, then the
    /// rest newest first (undated last). Empty when none is due, or only photos this run already handled.
    private func next(excluding handled: Set<Int64>, _ run: EmbedRun) async throws -> [Candidate] {
        let now = clock.now.timeIntervalSince1970
        let recent = Int64(now - policy.recentWindow), retry = Int64(now - policy.cloudRetry)
        let embeds = run.embeds, foreground = mode == .foreground
        // Asset ids are integers: written into the statement, they keep its arguments short.
        let reference = embeds && !run.reference.isEmpty ? run.reference.map(String.init).joined(separator: ",") : "0"
        let rows = try await database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT a.id, a.local_id, a.created_utc, a.adjusted_utc, v.asset_id AS known, v.status, v.labels_version, v.adjusted_utc AS seen,
                       v.checked_utc, v.embed_version, v.embed_units
                FROM asset a LEFT JOIN asset_visual v ON v.asset_id = a.id
                WHERE v.asset_id IS NULL OR v.labels_version < ? OR v.adjusted_utc IS NOT a.adjusted_utc OR (v.status = 2 AND v.checked_utc <= ?)
                   OR (? AND v.status = 1 AND (v.embed_version IS NULL OR v.embed_version < ? OR (? AND v.embed_units = ?)
                                               OR (v.embed_units = ? AND v.checked_utc <= ?)))
                ORDER BY a.id IN (\(reference)) DESC, a.created_utc >= ? DESC, a.created_utc IS NULL, a.created_utc DESC, a.id DESC
                LIMIT ?
                """, arguments: [VisualPass.version, retry, embeds, EmbedPass.version, foreground, EmbedUnits.cpu.rawValue, EmbedUnits.failed.rawValue,
                                 retry, recent, 2 * Self.window])
                .map { row in
                    let known = (row["known"] as Int64?) != nil
                    let adjusted: Int64? = row["adjusted_utc"]
                    let edited = known && (row["seen"] as Int64?) != adjusted
                    let status: Int? = row["status"], labels: Int? = row["labels_version"], checked: Int64? = row["checked_utc"]
                    let tags = !known || (labels ?? 0) < VisualPass.version || edited || (status == VisualStatus.pendingCloud.rawValue && (checked ?? 0) <= retry)
                    let embedVersion: Int? = row["embed_version"], embedUnits: Int? = row["embed_units"]
                    let stale = (embedVersion ?? 0) < EmbedPass.version || (foreground && embedUnits == EmbedUnits.cpu.rawValue)
                        || (embedUnits == EmbedUnits.failed.rawValue && (checked ?? 0) <= retry)
                    return Candidate(asset: VisualAsset(id: row["id"], localID: row["local_id"], createdUTC: row["created_utc"]), adjusted: adjusted,
                                     tags: tags, vector: embeds && (edited || stale), edited: edited, embedVersion: embedVersion, embedUnits: embedUnits)
                }
        }
        // Photos this run handled are written and no longer due; one that couldn't be written isn't picked twice.
        return Array(rows.filter { !handled.contains($0.asset.id) }.prefix(Self.window))
    }

    // MARK: Tagging and embedding

    private struct Result: Sendable {
        var candidate: Candidate
        var outcome: VisualOutcome
        /// The model was asked for its vector.
        var embedded: Bool
    }

    /// `batch` through the analyzer, ``VisualPolicy/concurrency`` at a time, with `embedder` for the photos whose vector
    /// is due; a cancelled task returns what it has.
    private func analyze(_ batch: [Candidate], embedder model: (any ImageEmbedder)?) async -> [Result] {
        let analyzer = analyzer, width = max(1, policy.concurrency)
        return await withTaskGroup(of: Result?.self) { group in
            var results: [Result] = []
            var pending = batch[...]
            func add() {
                guard let candidate = pending.popFirst() else { return }
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    let embedder = candidate.vector ? model : nil
                    let outcome = await analyzer.analyze(candidate.asset, tags: candidate.tags, embedder: embedder)
                    return Task.isCancelled ? nil : Result(candidate: candidate, outcome: outcome, embedded: embedder != nil)
                }
            }
            for _ in 0..<width { add() }
            while let result = await group.next() {
                if let result { results.append(result) }
                if !Task.isCancelled { add() }
            }
            return results
        }
    }

    /// The batch's vectors into the vector file, then one transaction: each photo whose tags were due has them
    /// replaced and its pass row written, each new vector recorded (photos deleted meanwhile are skipped). Vectors go
    /// first, so a crash between the two leaves a photo whose row says it has no vector yet: it is made again.
    /// Returns whether any row was written, and how many vectors.
    private func write(_ results: [Result], _ run: EmbedRun) async throws -> (rows: Bool, vectors: Int) {
        guard !results.isEmpty else { return (false, 0) }
        var entries: [VectorEntry] = [], stale: [Int64] = []
        for result in results where result.candidate.vector || result.candidate.edited {
            if case .analysed(_, let vector?) = result.outcome {
                entries.append(VectorEntry(assetID: result.candidate.asset.id, vector: vector))
            } else if result.candidate.edited {
                stale.append(result.candidate.asset.id)
            }
        }
        // Only vectors in the file are recorded as made.
        let made: Set<Int64>
        if let store = run.store {
            try await store.upsert(entries)
            try await store.remove(stale)
            made = Set(entries.map(\.assetID))
        } else {
            made = []
        }
        let units = EmbedUnits(run.embedder?.mode ?? mode).rawValue
        let now = Int64(clock.now.timeIntervalSince1970)
        let known = labelIDs
        let written = try await database.write { db -> (count: Int, ids: [String: Int64]) in
            var ids = known
            let marks = Array(repeating: "?", count: results.count).joined(separator: ", ")
            let present = Set(try Int64.fetchAll(db, sql: "SELECT id FROM asset WHERE id IN (\(marks))",
                                                 arguments: StatementArguments(results.map(\.candidate.asset.id))))
            var count = 0
            for result in results where present.contains(result.candidate.asset.id) {
                let candidate = result.candidate, asset = candidate.asset.id
                // The vector it ends with: the one just made; a failed try (tried again after the iCloud retry time); none
                // after an edit; or the one it had.
                let tried = result.embedded && !made.contains(asset)
                let embed: (version: Int?, units: Int?) = made.contains(asset) ? (EmbedPass.version, units)
                    : tried ? (EmbedPass.version, EmbedUnits.failed.rawValue) : candidate.edited ? (nil, nil) : (candidate.embedVersion, candidate.embedUnits)
                guard candidate.tags else {
                    if result.embedded {
                        try db.execute(sql: "UPDATE asset_visual SET embed_version = ?, embed_units = ?, checked_utc = ? WHERE asset_id = ?",
                                       arguments: [embed.version, embed.units, now, asset])
                        count += 1
                    }
                    continue
                }
                try db.execute(sql: "DELETE FROM asset_label WHERE asset_id = ?", arguments: [asset])
                var status = VisualStatus.failed
                var analysis: VisualAnalysis?
                switch result.outcome {
                case .analysed(let found, _):
                    status = .done
                    analysis = found
                case .inCloud: status = .pendingCloud
                case .failed: status = .failed
                }
                for label in analysis?.labels ?? [] {
                    let id: Int64
                    if let known = ids[label.name] {
                        id = known
                    } else {
                        try db.execute(sql: "INSERT OR IGNORE INTO visual_label (name) VALUES (?)", arguments: [label.name])
                        id = try Int64.fetchOne(db, sql: "SELECT id FROM visual_label WHERE name = ?", arguments: [label.name]) ?? -1
                        ids[label.name] = id
                    }
                    try db.execute(sql: "INSERT OR REPLACE INTO asset_label (label_id, asset_id, confidence, flags) VALUES (?, ?, ?, ?)",
                                   arguments: [id, asset, Double(label.confidence), Int(label.flags.rawValue)])
                }
                try db.execute(sql: """
                    INSERT OR REPLACE INTO asset_visual (asset_id, status, faces, humans, largest_face, is_utility, aesthetic, labels_version,
                                                         embed_version, embed_units, adjusted_utc, checked_utc)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [asset, status.rawValue, analysis?.faces, analysis?.humans, analysis?.largestFace, analysis?.isUtility,
                                     analysis?.aesthetic, VisualPass.version, embed.version, embed.units, candidate.adjusted, now])
                count += 1
            }
            return (count, ids)
        }
        labelIDs = written.ids
        return (written.count > 0, entries.count)
    }

    /// Search sees the tags written so far: a new index version, published by the indexer. Vectors of photos deleted
    /// meanwhile go.
    private func checkpoint(_ run: EmbedRun) async {
        _ = try? await database.write { db in try Meta.bumpVersion(db) }
        if let store = run.store { try? await reconcile(store, lost: false) }
        await refreshCounts()
        publish(broadcaster.latest.state)
        await notify()
        #if DEBUG
        let footprint = Self.footprint().map { "\($0 / 1_048_576) MB" } ?? "-"
        print("VISUAL \(counts.checked) of \(counts.total) checked, \(counts.pendingCloud) only in iCloud, "
              + "\(String(format: "%.1f", rate ?? 0)) photos/s, footprint \(footprint)"
              + (model == nil ? "" : "; EMBED \(counts.embedded) vectors, \(String(format: "%.1f", vectorRate ?? 0))/s, "
                 + "thermal peak \(peakThermal.rawValue), model load \(modelLoad.map { String(format: "%.2f s", $0.seconds) } ?? "-")"))
        #endif
    }

    // MARK: Progress

    private func refreshCounts() async {
        let fresh = try? await database.read { db in
            (checked: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_visual WHERE status = 1") ?? 0,
             pendingCloud: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_visual WHERE status = 2") ?? 0,
             total: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset") ?? 0,
             embedded: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_visual WHERE embed_units IN (?, ?)",
                                        arguments: [EmbedUnits.all.rawValue, EmbedUnits.cpu.rawValue]) ?? 0)
        }
        if let fresh { counts = fresh }
    }

    private func publish(_ state: VisualProgress.State) {
        let footprint = Self.footprint()
        if let footprint, footprint > peakFootprint ?? 0 { peakFootprint = footprint }
        let progress = VisualProgress(checked: counts.checked, pendingCloud: counts.pendingCloud, total: counts.total, state: state,
                                      photosPerSecond: rate, footprint: footprint, embedded: model == nil ? nil : counts.embedded,
                                      vectorsPerSecond: vectorRate, peakFootprint: peakFootprint, peakThermal: peakThermal, modelLoad: modelLoad)
        if progress != broadcaster.latest { broadcaster.send(progress) }
    }

    /// The process's physical footprint (what iOS's memory limit counts), in bytes.
    public static func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }
}
