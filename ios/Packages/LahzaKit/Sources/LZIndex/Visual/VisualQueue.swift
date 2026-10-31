import Darwin
import Foundation
import LZCore
internal import GRDB

/// P1a's tunables (placeholders to tune on the iPhone).
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

    public init(batchSize: Int = 32, concurrency: Int = 2, checkpointInterval: Duration = .seconds(3), cloudRetry: TimeInterval = 6 * 3_600,
                recentWindow: TimeInterval = 365 * 86_400, thermalPause: Duration = .seconds(30)) {
        self.batchSize = batchSize
        self.concurrency = concurrency
        self.checkpointInterval = checkpointInterval
        self.cloudRetry = cloudRetry
        self.recentWindow = recentWindow
        self.thermalPause = thermalPause
    }

    public static let `default` = VisualPolicy()
}

/// How far the Vision pass has got (Settings, the label lab, the coverage line).
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
    /// Tagged per second over the latest run (nil before one has tagged anything).
    public var photosPerSecond: Double?
    /// The app's memory footprint at the latest checkpoint, in bytes.
    public var footprint: UInt64?

    public init(checked: Int = 0, pendingCloud: Int = 0, total: Int = 0, state: State = .idle, photosPerSecond: Double? = nil, footprint: UInt64? = nil) {
        self.checked = checked
        self.pendingCloud = pendingCloud
        self.total = total
        self.state = state
        self.photosPerSecond = photosPerSecond
        self.footprint = footprint
    }
}

/// P1a: tags every photo with Vision, on the iPhone (content search L2). Like ``PlaceNameQueue`` it is its own actor,
/// writes only its own tables (`visual_label`, `asset_label`, `asset_visual`), runs only while Lahza is open, and asks
/// the indexer to publish the new index version at checkpoints (`notify`), so search sees the tags as they come.
///
/// Order: the last 12 months newest first, then everything older, newest first. A photo is tagged again after a
/// content edit (`adjusted_utc`), a ``VisualPass`` bump, or a changed Vision tag list (an iOS update); one only in
/// iCloud after ``VisualPolicy/cloudRetry``. It pauses while the iPhone is seriously hot and stops when critically hot.
/// ``run()`` returns when nothing is left to tag now, or when its task is cancelled.
public actor VisualQueue {
    private let database: IndexDatabase
    private let analyzer: any VisualAnalyzer
    private let clock: any AppClock
    private let notify: @Sendable () async -> Void
    private let policy: VisualPolicy
    private let broadcaster: Broadcaster<VisualProgress>
    private let log = Log("visual")

    private var labelIDs: [String: Int64] = [:]
    private var counts = (checked: 0, pendingCloud: 0, total: 0)
    private var rate: Double?

    /// Candidates read at a time.
    static let window = 512

    public init(database: IndexDatabase, analyzer: any VisualAnalyzer, clock: any AppClock, notify: @escaping @Sendable () async -> Void,
                policy: VisualPolicy = .default) {
        self.database = database
        self.analyzer = analyzer
        self.clock = clock
        self.notify = notify
        self.policy = policy
        broadcaster = Broadcaster(VisualProgress())
    }

    /// Checked photos and what the queue is doing: a fresh stream per subscriber, newest only.
    public nonisolated var progress: AsyncStream<VisualProgress> { broadcaster.stream() }

    // MARK: Run

    private struct Candidate: Sendable {
        var asset: VisualAsset
        var adjusted: Int64?
    }

    /// Tags photos until none is due or the task is cancelled. The caller owns the task.
    public func run() async {
        do {
            if try await prepare() { await notify() }
        } catch {
            log.error("Vision pass setup failed: \(IndexDatabase.code(of: error))", privacy: .public)
            return
        }
        await refreshCounts()
        var handled = Set<Int64>()
        var tagged = 0
        var activeSeconds = 0.0
        var lastCheckpoint = ContinuousClock.now
        var unpublished = false
        loop: while !Task.isCancelled {
            let thermal = ProcessInfo.processInfo.thermalState
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
                candidates = try await next(excluding: handled)
            } catch {
                log.error("Vision pass read failed: \(IndexDatabase.code(of: error))", privacy: .public)
                break
            }
            guard !candidates.isEmpty else { break }
            publish(.running)
            for start in stride(from: 0, to: candidates.count, by: policy.batchSize) {
                let batch = Array(candidates[start..<min(candidates.count, start + policy.batchSize)])
                let started = ContinuousClock.now
                let results = await analyze(batch)
                for candidate in batch { handled.insert(candidate.asset.id) }
                do {
                    if try await write(results) { unpublished = true }
                } catch {
                    log.error("Vision pass write failed: \(IndexDatabase.code(of: error))", privacy: .public)
                    break loop
                }
                tagged += results.count
                activeSeconds += (ContinuousClock.now - started).seconds
                rate = activeSeconds > 0 ? Double(tagged) / activeSeconds : nil
                if unpublished, ContinuousClock.now - lastCheckpoint >= policy.checkpointInterval {
                    await checkpoint()
                    unpublished = false
                    lastCheckpoint = ContinuousClock.now
                }
                if Task.isCancelled || ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue { continue loop }
            }
        }
        if unpublished { await checkpoint() }
        if tagged > 0 {
            log.info("Vision pass: \(tagged) tagged at \(String(format: "%.1f", rate ?? 0))/s, \(counts.checked) of \(counts.total) checked, "
                     + "\(counts.pendingCloud) only in iCloud", privacy: .public)
        }
        if !Task.isCancelled, broadcaster.latest.state != .tooHot { publish(.done) }
    }

    /// Records the tag list and the pass version; returns whether search must be told (the pass just started, or
    /// every photo is due again).
    private func prepare() async throws -> Bool {
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
        return ids.changed
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

    // MARK: Picking

    /// The next photos due: the last 12 months newest first, then the rest newest first (undated last). Empty when none
    /// is due, or only photos this run already handled.
    private func next(excluding handled: Set<Int64>) async throws -> [Candidate] {
        let now = clock.now.timeIntervalSince1970
        let recent = Int64(now - policy.recentWindow), retry = Int64(now - policy.cloudRetry)
        let rows = try await database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT a.id, a.local_id, a.created_utc, a.adjusted_utc FROM asset a LEFT JOIN asset_visual v ON v.asset_id = a.id
                WHERE v.asset_id IS NULL OR v.labels_version < ? OR v.adjusted_utc IS NOT a.adjusted_utc OR (v.status = 2 AND v.checked_utc <= ?)
                ORDER BY a.created_utc >= ? DESC, a.created_utc IS NULL, a.created_utc DESC, a.id DESC
                LIMIT ?
                """, arguments: [VisualPass.version, retry, recent, 2 * Self.window]).map { row in
                Candidate(asset: VisualAsset(id: row["id"], localID: row["local_id"], createdUTC: row["created_utc"]), adjusted: row["adjusted_utc"])
            }
        }
        // Photos this run tagged are written and no longer due; one that couldn't be written isn't picked twice.
        return Array(rows.filter { !handled.contains($0.asset.id) }.prefix(Self.window))
    }

    // MARK: Tagging

    private struct Result: Sendable {
        var candidate: Candidate
        var outcome: VisualOutcome
    }

    /// `batch` through the analyzer, ``VisualPolicy/concurrency`` at a time; a cancelled task returns what it has.
    private func analyze(_ batch: [Candidate]) async -> [Result] {
        let analyzer = analyzer, width = max(1, policy.concurrency)
        return await withTaskGroup(of: Result?.self) { group in
            var results: [Result] = []
            var pending = batch[...]
            func add() {
                guard let candidate = pending.popFirst() else { return }
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    let outcome = await analyzer.analyze(candidate.asset)
                    return Task.isCancelled ? nil : Result(candidate: candidate, outcome: outcome)
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

    /// One transaction: each photo's tags replaced and its pass row written (photos deleted meanwhile are skipped).
    /// Returns whether anything was written.
    private func write(_ results: [Result]) async throws -> Bool {
        guard !results.isEmpty else { return false }
        let now = Int64(clock.now.timeIntervalSince1970)
        let known = labelIDs
        let written = try await database.write { db -> (count: Int, ids: [String: Int64]) in
            var ids = known
            let marks = Array(repeating: "?", count: results.count).joined(separator: ", ")
            let present = Set(try Int64.fetchAll(db, sql: "SELECT id FROM asset WHERE id IN (\(marks))",
                                                 arguments: StatementArguments(results.map(\.candidate.asset.id))))
            var count = 0
            for result in results where present.contains(result.candidate.asset.id) {
                let asset = result.candidate.asset.id
                try db.execute(sql: "DELETE FROM asset_label WHERE asset_id = ?", arguments: [asset])
                var status = VisualStatus.failed
                var analysis: VisualAnalysis?
                switch result.outcome {
                case .analysed(let found):
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
                                                         embed_version, adjusted_utc, checked_utc)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?)
                    """, arguments: [asset, status.rawValue, analysis?.faces, analysis?.humans, analysis?.largestFace, analysis?.isUtility,
                                     analysis?.aesthetic, VisualPass.version, result.candidate.adjusted, now])
                count += 1
            }
            return (count, ids)
        }
        labelIDs = written.ids
        return written.count > 0
    }

    /// Search sees the tags written so far: a new index version, published by the indexer.
    private func checkpoint() async {
        _ = try? await database.write { db in try Meta.bumpVersion(db) }
        await refreshCounts()
        publish(broadcaster.latest.state)
        await notify()
        #if DEBUG
        let footprint = Self.footprint().map { "\($0 / 1_048_576) MB" } ?? "-"
        print("VISUAL \(counts.checked) of \(counts.total) checked, \(counts.pendingCloud) only in iCloud, "
              + "\(String(format: "%.1f", rate ?? 0)) photos/s, footprint \(footprint)")
        #endif
    }

    // MARK: Progress

    private func refreshCounts() async {
        let fresh = try? await database.read { db in
            (checked: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_visual WHERE status = 1") ?? 0,
             pendingCloud: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_visual WHERE status = 2") ?? 0,
             total: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset") ?? 0)
        }
        if let fresh { counts = fresh }
    }

    private func publish(_ state: VisualProgress.State) {
        let progress = VisualProgress(checked: counts.checked, pendingCloud: counts.pendingCloud, total: counts.total, state: state,
                                      photosPerSecond: rate, footprint: Self.footprint())
        if progress != broadcaster.latest { broadcaster.send(progress) }
    }

    /// The process's physical footprint (what iOS's memory limit counts), in bytes.
    static func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }
}
