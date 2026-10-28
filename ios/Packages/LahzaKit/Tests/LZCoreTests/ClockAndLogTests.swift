import Foundation
import Synchronization
import Testing
@testable import LZCore

/// A lock-protected box that escaping test tasks can share.
final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>
    init(_ value: Value) { mutex = Mutex(value) }
    func withLock<R: Sendable>(_ body: (inout Value) -> R) -> R { mutex.withLock { body(&$0) } }
}

extension Date {
    /// A date this many milliseconds after 1970-01-01T00:00:00Z.
    fileprivate init(epochMilliseconds: Int64) {
        self.init(timeIntervalSince1970: Double(epochMilliseconds) / 1000)
    }

    /// Whole milliseconds since 1970 (rounded), so clock assertions read as plain numbers.
    fileprivate var epochMilliseconds: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }
}

@Suite("Clock and Log")
struct ClockAndLogTests {
    @Test("FixedClock is settable and advances; time stands still otherwise")
    func fixedClockTime() async throws {
        let clock = try #require(FixedClock(iso: "2026-09-24T08:30:00.000Z"))
        #expect(clock.now.epochMilliseconds == 1_790_238_600_000)
        await clock.advance(by: 1.5)
        #expect(clock.now.epochMilliseconds == 1_790_238_601_500)
        await clock.advance(by: .milliseconds(800))
        #expect(clock.now.epochMilliseconds == 1_790_238_602_300)
        await clock.advance(by: .seconds(60))
        #expect(clock.now.epochMilliseconds == 1_790_238_662_300)
        clock.set(Date(epochMilliseconds: 0))
        #expect(clock.now == Date(timeIntervalSince1970: 0))
        // ISO input: with or without fractional seconds, Z or an offset; nothing else.
        #expect(FixedClock(iso: "2026-09-24T08:30:00Z")?.now.epochMilliseconds == 1_790_238_600_000)
        #expect(FixedClock(iso: "2026-09-24T10:30:00.250+02:00")?.now.epochMilliseconds == 1_790_238_600_250)
        #expect(FixedClock(iso: "not a date") == nil)
        #expect(FixedClock(iso: "2026-09-24T08:30:00") == nil)
        // The stdlib Clock is not shadowed by LZCore.
        let continuous: any Clock<Duration> = ContinuousClock()
        #expect(continuous.minimumResolution >= .zero)
    }

    @Test("sleep suspends until advance passes its deadline")
    func sleepWaitsForAdvance() async throws {
        let clock = FixedClock(Date(epochMilliseconds: 0))
        let fired = Locked<[Int64]>([])
        let task = Task {
            try await clock.sleep(for: .milliseconds(800))
            fired.withLock { $0.append(clock.now.epochMilliseconds) }
        }
        #expect(await clock.waitForSleepers(1))
        #expect(clock.nextDeadline?.epochMilliseconds == 800)
        await clock.advance(by: .milliseconds(799))
        #expect(fired.withLock { $0 }.isEmpty)
        #expect(clock.now.epochMilliseconds == 799)
        await clock.advance(by: .milliseconds(1))
        try await task.value
        #expect(fired.withLock { $0 } == [800])
        #expect(clock.pendingSleepCount == 0)
    }

    @Test("Concurrent sleepers fire in deadline order at their own deadlines; durations do not add up")
    func concurrentSleepers() async throws {
        let clock = FixedClock(Date(epochMilliseconds: 0))
        let fired = Locked<[String]>([])
        let periodic = Task {
            try await clock.sleep(for: .seconds(60))
            fired.withLock { $0.append("sync@\(clock.now.epochMilliseconds)") }
        }
        let debounce = Task {
            try await clock.sleep(for: .milliseconds(800))
            fired.withLock { $0.append("push@\(clock.now.epochMilliseconds)") }
        }
        #expect(await clock.waitForSleepers(2))
        await clock.advance(by: .seconds(60))
        try await periodic.value
        try await debounce.value
        #expect(fired.withLock { $0 } == ["push@800", "sync@60000"])
        #expect(clock.now.epochMilliseconds == 60_000)
    }

    @Test("A second edit within 800 ms cancels the pending push and restarts the debounce")
    func debounceCoalesces() async throws {
        let clock = FixedClock(Date(epochMilliseconds: 0))
        let pushes = Locked(0)
        func schedulePush() -> Task<Void, any Error> {
            Task {
                try await clock.sleep(for: .milliseconds(800))
                pushes.withLock { $0 += 1 }
            }
        }
        let first = schedulePush()
        #expect(await clock.waitForSleepers(1))
        await clock.advance(by: .milliseconds(500))
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        let second = schedulePush()
        #expect(await clock.waitForSleepers(1))
        await clock.advance(by: .milliseconds(799))
        #expect(pushes.withLock { $0 } == 0)
        await clock.advance(by: .milliseconds(1))
        try await second.value
        #expect(pushes.withLock { $0 } == 1)
        #expect(clock.now.epochMilliseconds == 1_300)
    }

    @Test("A sleeper that sleeps again inside the advanced window fires again")
    func rescheduling() async throws {
        let clock = FixedClock(Date(epochMilliseconds: 0))
        let ticks = Locked<[Int64]>([])
        let task = Task {
            for _ in 0..<3 {
                try await clock.sleep(for: .seconds(60))
                ticks.withLock { $0.append(clock.now.epochMilliseconds) }
            }
        }
        #expect(await clock.waitForSleepers(1))
        await clock.advance(by: .seconds(180))
        try await task.value
        #expect(ticks.withLock { $0 } == [60_000, 120_000, 180_000])
    }

    @Test("Zero and negative sleeps return at once; cancelled sleeps throw; run drains sleepers; set fires due sleepers")
    func edgeCases() async throws {
        let clock = FixedClock(Date(epochMilliseconds: 1_000))
        try await clock.sleep(for: .zero)
        try await clock.sleep(for: .milliseconds(-5))
        #expect(clock.now.epochMilliseconds == 1_000)

        let cancelled = Task {
            try await clock.sleep(for: .seconds(10))
        }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(clock.pendingSleepCount == 0)

        let drained = Task { try await clock.sleep(for: .seconds(5)) }
        #expect(await clock.waitForSleepers(1))
        #expect(await clock.run())
        try await drained.value
        #expect(clock.now.epochMilliseconds == 6_000)

        let viaSet = Task { try await clock.sleep(for: .seconds(1)) }
        #expect(await clock.waitForSleepers(1))
        clock.set(Date(epochMilliseconds: 10_000))
        try await viaSet.value
        #expect(clock.now.epochMilliseconds == 10_000)
        #expect(await clock.waitForSleepers(1, maxYields: 3) == false)
    }

    @Test("SystemClock tracks the real time")
    func systemClock() async throws {
        let clock: any AppClock = SystemClock()
        let before = Date()
        let now = clock.now
        #expect(now.timeIntervalSince(before) < 1)
        let start = ContinuousClock.now
        try await clock.sleep(for: .milliseconds(5))
        #expect(ContinuousClock.now - start >= .milliseconds(5))
    }

    @Test("Log writes without trapping at every level and privacy")
    func log() {
        let log = Log("tests")
        #expect(log.category == "tests")
        log.debug("debug")
        log.info("info", privacy: .public)
        log.notice("notice")
        log.error("error", privacy: .public)
        log.fault("fault")
        Log.core.info("core")
    }
}
