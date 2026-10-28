import Foundation
import Testing
@testable import LZLibrary

/// The census runner over the fake library: the stages in order, cancellation, access, and a
/// synthetic library that is deterministic and realistic.
@MainActor @Suite struct CensusRunnerTests {
    @Test func runsEveryStageAndReports() async throws {
        let runner = CensusRunner(source: FakeCensusSource(library: FakePhotoLibraryClient(access: .full), pace: .zero))
        #expect(runner.phase == .idle)
        await runner.run()
        let report = try #require(runner.report)
        #expect(report.library.total == 12_480)
        #expect(report.access == .full)
        #expect(report.source == "Sample library")
        #expect(report.received.filenamesRead)
        #expect(report.thumbnails?.sampled == CensusRunner.defaultSampleSize)
        #expect(runner.timings.metadata != nil)
        #expect(runner.timings.filenames != nil)
        #expect(runner.timings.thumbnails != nil)
        #expect(runner.timings.total != nil)
        #expect(report.speed.metadataSecondsPer30k != nil)
        #expect(runner.progress == nil)
    }

    @Test func walksTheStagesInOrder() async throws {
        let runner = CensusRunner(source: FakeCensusSource(library: FakePhotoLibraryClient(access: .full), pace: .milliseconds(2)))
        let run = runner.start()
        var seen: [Int] = []
        while runner.phase.isRunning {
            if let stage = runner.phase.stage, seen.last != stage { seen.append(stage) }
            try await Task.sleep(for: .milliseconds(1))
        }
        await run.value
        #expect(seen == [1, 2, 3])
        #expect(runner.report != nil)
    }

    @Test func limitedAccessCountsOnlyWhatWasShared() async throws {
        let runner = CensusRunner(source: FakeCensusSource(library: FakePhotoLibraryClient(access: .limited), pace: .zero))
        await runner.run()
        let report = try #require(runner.report)
        #expect(report.library.total == 36)
        #expect(report.access == .limited)
    }

    @Test(arguments: [PhotoAccess.notDetermined, .denied, .restricted])
    func withoutAccessItFails(_ access: PhotoAccess) async {
        let runner = CensusRunner(source: FakeCensusSource(library: FakePhotoLibraryClient(access: access), pace: .zero))
        await runner.run()
        #expect(runner.phase == .failed(.noAccess))
        #expect(runner.report == nil)
    }

    @Test func cancelDuringTheMetadataPassKeepsNothing() async throws {
        let runner = CensusRunner(source: FakeCensusSource(library: FakePhotoLibraryClient(access: .full), pace: .milliseconds(5)))
        let run = runner.start()
        try await waitUntil { (runner.progress?.done ?? 0) > 0 }
        #expect(runner.phase == .metadata)
        runner.cancel()
        await run.value
        #expect(runner.phase == .cancelled)
        #expect(runner.progress == nil)
        #expect(runner.report == nil)
    }

    @Test func cancelDuringTheThumbnailSample() async throws {
        let runner = CensusRunner(source: FakeCensusSource(library: FakePhotoLibraryClient(access: .full), pace: .milliseconds(2)))
        let run = runner.start()
        try await waitUntil(seconds: 10) { runner.phase == .thumbnails }
        runner.cancel()
        await run.value
        #expect(runner.phase == .cancelled)
        #expect(runner.timings.metadata != nil)
        #expect(runner.timings.thumbnails == nil)
    }

    @Test func startWhileRunningJoinsTheRun() async {
        let runner = CensusRunner(source: FakeCensusSource(library: FakePhotoLibraryClient(access: .full), pace: .milliseconds(1)))
        let first = runner.start()
        let second = runner.start()
        #expect(first == second)
        runner.cancel()
        await first.value
        // After a run ends, start begins a new one.
        let third = runner.start()
        #expect(third != first)
        await third.value
        #expect(runner.report != nil)
    }

    @Test func aCancelledRerunKeepsTheLastReport() async throws {
        let runner = CensusRunner(source: FakeCensusSource(library: FakePhotoLibraryClient(access: .full), pace: .milliseconds(1)))
        await runner.run()
        let first = try #require(runner.report)
        let rerun = runner.start()
        #expect(runner.report == first)
        runner.cancel()
        await rerun.value
        #expect(runner.phase == .cancelled)
        #expect(runner.report == first)
    }

    @Test func aMisbehavingSourceFailsCleanly() async {
        // Fewer hints than facts would otherwise index past the end mid-census.
        let short = CensusRunner(source: BrokenSource(failure: .shortHints))
        await short.run()
        #expect(short.phase == .failed(.mismatchedScan))
        #expect(short.progress == nil)
        #expect(short.report == nil)

        let foreign = CensusRunner(source: BrokenSource(failure: .foreignError))
        await foreign.run()
        guard case .failed(.unexpected) = foreign.phase else {
            Issue.record("expected an unexpected failure, got \(foreign.phase)")
            return
        }
        #expect(foreign.progress == nil)
        #expect(foreign.report == nil)
    }

    @Test func leavingTheForegroundMarksOnlyARunningCensus() async throws {
        let runner = CensusRunner(source: FakeCensusSource(library: FakePhotoLibraryClient(access: .full), pace: .zero))
        await runner.run()
        runner.appLeftForeground()
        #expect(!runner.timings.interrupted, "a finished run's times are already measured")
        #expect(runner.report?.speed.interrupted == false)

        let rerun = runner.start()
        runner.appLeftForeground()
        await rerun.value
        #expect(runner.timings.interrupted)
        let report = try #require(runner.report)
        #expect(report.speed.interrupted)
        #expect(report.verdicts.metadataSpeed == .unavailable)
    }

    @Test func theSharedReportNamesNoFile() async throws {
        let runner = CensusRunner(source: FakeCensusSource(library: FakePhotoLibraryClient(access: .full), pace: .zero))
        await runner.run()
        let text = try #require(runner.report?.text)
        // The fake's synthetic names: none may reach the report.
        for name in ["IMG_", "IMG-", "-WA", "photo_", "signal-", "RPReplay", "DSC_", "scan1", ".HEIC", ".JPG", ".jpg", ".PNG", ".MOV", ".mp4"] {
            #expect(!text.contains(name), "the report contains \(name)")
        }
    }

    // MARK: The synthetic library

    @Test func theFakeLibraryIsDeterministic() {
        let first = SyntheticLibrary(count: 2_000, seed: 7)
        let second = SyntheticLibrary(count: 2_000, seed: 7)
        #expect(first.facts == second.facts)
        #expect(first.names == second.names)
        #expect(first.extraBurstFrames == second.extraBurstFrames)
        #expect(SyntheticLibrary(count: 2_000, seed: 8).facts != first.facts)
        #expect(SyntheticLibrary(count: 0, seed: 7).facts.isEmpty)
    }

    @Test func theFakeLibraryLooksLikeARealOne() throws {
        let synthetic = SyntheticLibrary(count: 12_480, seed: 2026)
        let hints = synthetic.names.map(FilenameHint.init(filename:))
        let scan = try CensusScan(facts: synthetic.facts, access: .full, extraBurstFrames: synthetic.extraBurstFrames).applying(hints)
        let context = CensusContext(sourceName: "Sample library", device: .current(), generatedAt: Date(timeIntervalSince1970: 1_793_000_000),
                                    calendar: Calendar(identifier: .gregorian))
        let report = LibraryCensus.summarize(scan, thumbnails: nil, timings: CensusTimings(), context: context)
        let library = report.library
        #expect(library.total == 12_480)
        #expect((0.8...0.95).contains(Double(library.photos) / Double(library.total)))
        #expect(library.screenshots > 0 && library.livePhotos > 0 && library.favorites > 0)
        // Camera photos are mostly located: the place mark passes.
        #expect(report.verdicts.placeSignal == .pass)
        #expect(report.received.likelyPhotos > 0)
        #expect(report.received.namedWhatsApp > 0 && report.received.namedTelegram > 0 && report.received.namedOtherMessaging > 0)
        #expect(report.duplicates.groups > 0 && report.duplicates.burstStacks > 0)
        #expect((report.duplicates.extraBurstFrames ?? 0) > 0)
        #expect(report.dates.missing > 0 && report.dates.before2000 > 0 && report.dates.inFuture > 0)
        #expect(report.video.count > 0 && report.video.upTo10Minutes < report.video.count)
        #expect(report.moments.count > 100)
    }

    /// Polls `condition` (stage work lands on later turns of the main actor).
    private func waitUntil(seconds: Int = 2, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

/// A source that scans one photo, then misbehaves in the filename pass.
private struct BrokenSource: CensusSource {
    enum Failure: Sendable {
        /// Returns fewer hints than there are facts.
        case shortHints
        /// Throws an error that isn't a ``CensusError``.
        case foreignError
    }

    struct Foreign: Error {}

    let failure: Failure
    let name = "Broken"

    func scanMetadata(progress: CensusProgressHandler) async throws -> CensusScan {
        progress(CensusProgress(done: 1, total: 1))
        return CensusScan(facts: [AssetFacts(kind: .photo)], access: .full)
    }

    func scanFilenames(of scan: CensusScan, progress: CensusProgressHandler) async throws -> [FilenameHint] {
        switch failure {
        case .shortHints: return []
        case .foreignError: throw Foreign()
        }
    }

    func probeThumbnails(of scan: CensusScan, sampleSize: Int, progress: CensusProgressHandler) async throws -> ThumbnailProbe {
        ThumbnailTally(requested: sampleSize).result(total: .zero)
    }
}
