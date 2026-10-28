import DDCore
import Foundation
import Observation

/// Runs a library census (Phase 0 spike S2) for the DEBUG census screen: the metadata pass, the
/// filename pass and the thumbnail sample, then ``LibraryCensus`` summarises off the main actor.
/// Each stage is timed on a monotonic clock and reports progress; ``cancel()`` stops between
/// batches and keeps nothing from that run. ``appLeftForeground()`` marks a run whose times include
/// a pause.
///
/// Per-asset facts live only inside a run. The finished ``CensusReport`` holds aggregates, and the
/// log gets counts and timings only.
@MainActor @Observable public final class CensusRunner {
    public enum Phase: Sendable, Hashable {
        case idle
        /// Stage 1: reading every asset's metadata.
        case metadata
        /// Stage 2: classifying original filenames.
        case filenames
        /// Stage 3: probing local thumbnails on a sample.
        case thumbnails
        case done(CensusReport)
        case failed(CensusError)
        case cancelled

        public var isRunning: Bool { stage != nil }

        /// 1…``CensusRunner/stageCount`` while running.
        public var stage: Int? {
            switch self {
            case .metadata: 1
            case .filenames: 2
            case .thumbnails: 3
            default: nil
            }
        }
    }

    public nonisolated static let stageCount = 3
    /// How many photos the thumbnail stage samples by default.
    public nonisolated static let defaultSampleSize = 300

    public private(set) var phase: Phase = .idle
    /// The running stage's progress (nil before it reports, and between runs).
    public private(set) var progress: CensusProgress?
    /// The latest run's stage timings.
    public private(set) var timings = CensusTimings()
    /// The latest finished report. A new run keeps it until that run finishes, so cancelling the
    /// new run (or a failure) doesn't lose results that may not have been shared yet.
    public private(set) var report: CensusReport?

    @ObservationIgnored private let source: any CensusSource
    @ObservationIgnored private let device: DeviceInfo
    @ObservationIgnored private let clock: any AppClock
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let sampleSize: Int
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let log = Log("census")

    public init(source: any CensusSource, device: DeviceInfo = .current(), clock: any AppClock = SystemClock(),
                calendar: Calendar = .autoupdatingCurrent, sampleSize: Int = CensusRunner.defaultSampleSize) {
        self.source = source
        self.device = device
        self.clock = clock
        self.calendar = calendar
        self.sampleSize = sampleSize
    }

    /// The source's name ("PhotoKit", "Sample library").
    public var sourceName: String { source.name }

    /// Starts a run and returns its task; while one is running, returns that one.
    @discardableResult
    public func start() -> Task<Void, Never> {
        if phase.isRunning, let task { return task }
        phase = .metadata
        progress = nil
        timings = CensusTimings()
        let task = Task { await perform() }
        self.task = task
        return task
    }

    /// Runs a census to the end (or until cancelled).
    public func run() async {
        await start().value
    }

    /// Stops the running census; it ends ``Phase/cancelled``.
    public func cancel() {
        task?.cancel()
    }

    /// Lahza went to the background (the app calls this from its scene phase). The monotonic clock
    /// keeps counting while the app is suspended or the iPhone sleeps, so a running census's times
    /// now include a pause: the report says so and doesn't judge the speed.
    public func appLeftForeground() {
        guard phase.isRunning else { return }
        timings.interrupted = true
    }

    // MARK: Stages

    private func perform() async {
        let clock = ContinuousClock()
        let started = clock.now
        let source = source
        let sampleSize = sampleSize
        do {
            let metadata = try await stage(.metadata) { try await source.scanMetadata(progress: $0) }
            let hints = try await stage(.filenames) { try await source.scanFilenames(of: metadata, progress: $0) }
            let scan = try metadata.applying(hints)
            let probe = try await stage(.thumbnails) { try await source.probeThumbnails(of: scan, sampleSize: sampleSize, progress: $0) }
            timings.total = clock.now - started
            let context = CensusContext(sourceName: source.name, device: device, generatedAt: self.clock.now, calendar: calendar)
            let report = await Self.summarize(scan, thumbnails: probe, timings: timings, context: context)
            try Task.checkCancellation()
            progress = nil
            self.report = report
            phase = .done(report)
            log.info("Census done: \(report.library.total) assets, \(String(format: "%.1f", timings.total?.seconds ?? 0)) s", privacy: .public)
        } catch is CancellationError {
            progress = nil
            phase = .cancelled
            log.info("Census cancelled", privacy: .public)
        } catch let error as CensusError {
            progress = nil
            phase = .failed(error)
            log.error("Census failed: \(error == .noAccess ? "no access" : "mismatched scan")", privacy: .public)
        } catch {
            progress = nil
            phase = .failed(.unexpected(String(describing: error)))
            log.error("Census failed", privacy: .public)
        }
    }

    /// Runs one stage: shows it, follows its progress in order, and times it.
    private func stage<Value: Sendable>(_ phase: Phase, _ work: @escaping @Sendable (CensusProgressHandler) async throws -> Value) async throws -> Value {
        self.phase = phase
        progress = nil
        // A stream keeps progress in order; a burst of updates collapses into the newest.
        let (updates, continuation) = AsyncStream.makeStream(of: CensusProgress.self, bufferingPolicy: .bufferingNewest(1))
        let follower = Task { [weak self] in
            for await update in updates { self?.progress = update }
        }
        defer { continuation.finish() }
        let clock = ContinuousClock()
        let begun = clock.now
        let value = try await work { continuation.yield($0) }
        let elapsed = clock.now - begun
        continuation.finish()
        await follower.value
        switch phase {
        case .metadata: timings.metadata = elapsed
        case .filenames: timings.filenames = elapsed
        case .thumbnails: timings.thumbnails = elapsed
        default: break
        }
        try Task.checkCancellation()
        return value
    }

    @concurrent private nonisolated static func summarize(_ scan: CensusScan, thumbnails: ThumbnailProbe, timings: CensusTimings,
                                                          context: CensusContext) async -> CensusReport {
        LibraryCensus.summarize(scan, thumbnails: thumbnails, timings: timings, context: context)
    }
}
