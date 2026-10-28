import Foundation
import Synchronization

/// Wall-clock time and sleeping, injectable so debounce, TTL and scheduling logic is
/// deterministic in tests.
///
/// It is named `AppClock` rather than `Clock`, so it does not shadow the standard library's
/// `Clock` protocol in modules that import LZCore.
public protocol AppClock: Sendable {
    /// The current instant.
    var now: Date { get }
    /// Suspends for `duration`, throwing `CancellationError` if the task is cancelled first.
    func sleep(for duration: Duration) async throws
}

/// The real clock: `Date()` and `Task.sleep`.
public struct SystemClock: AppClock {
    public init() {}
    public var now: Date { Date() }
    public func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}

/// A manually driven clock for tests. Time stands still until the test moves it.
///
/// ``sleep(for:)`` suspends until ``advance(by:)-(Duration)`` (or ``set(_:)``) moves ``now`` to or
/// past the sleeper's deadline, the way a real timer fires. Due sleepers resume one at a time in
/// deadline order (ties in the order they started sleeping), with ``now`` set to each deadline as
/// it fires, so an 800 ms debounce and a 60 s periodic sync sleeping at once fire at +0.8 s and
/// +60 s. A sleep of zero or less returns at once. A cancelled sleeper throws
/// `CancellationError`, so "a second edit within 800 ms cancels the first push" can be tested:
///
/// ```swift
/// let clock = FixedClock(Date(timeIntervalSince1970: 0))
/// let first = Task { try await clock.sleep(for: .milliseconds(800)); await push() }
/// #expect(await clock.waitForSleepers(1))
/// await clock.advance(by: .milliseconds(500))   // nothing fires
/// first.cancel()                                  // the second edit restarts the debounce
/// ```
///
/// Resumed sleepers run on the global executor; each advance step yields to other tasks (20
/// detached round trips) before firing the next deadline, which is what makes ordering
/// assertions reliable in practice.
public final class FixedClock: AppClock {
    private struct Sleeper {
        let id: UInt64
        let deadline: Date
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: Date
        var nextID: UInt64 = 0
        var sleepers: [Sleeper] = []
        /// Sleeps that started but have not registered their continuation yet.
        var starting: [UInt64: Date] = [:]
        /// Sleeps cancelled between starting and registering.
        var cancelledWhileStarting: Set<UInt64> = []

        /// Removes and returns the earliest sleeper due at or before `limit`, moving `now` to its
        /// deadline.
        mutating func popDue(upTo limit: Date) -> Sleeper? {
            var best: Int?
            for index in sleepers.indices where sleepers[index].deadline <= limit {
                if let current = best {
                    let a = sleepers[index], b = sleepers[current]
                    if a.deadline < b.deadline || (a.deadline == b.deadline && a.id < b.id) { best = index }
                } else {
                    best = index
                }
            }
            guard let best else { return nil }
            let sleeper = sleepers.remove(at: best)
            if sleeper.deadline > now { now = sleeper.deadline }
            return sleeper
        }
    }

    private let state: Mutex<State>

    /// Starts at `date`.
    public init(_ date: Date) {
        state = Mutex(State(now: date))
    }

    /// Starts at an ISO 8601 date-time with a zone (`2026-09-24T08:30:00Z`, optionally with
    /// fractional seconds or an offset such as `+02:00`); nil if invalid.
    public convenience init?(iso: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: iso) {
            self.init(date)
            return
        }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: iso) else { return nil }
        self.init(date)
    }

    public var now: Date { state.withLock { $0.now } }

    /// How many tasks are suspended in ``sleep(for:)``.
    public var pendingSleepCount: Int { state.withLock { $0.sleepers.count } }

    /// The earliest pending deadline, if any task is sleeping.
    public var nextDeadline: Date? { state.withLock { $0.sleepers.map(\.deadline).min() } }

    /// Moves the clock to `date` at once (forwards or backwards) and resumes, in deadline order,
    /// every sleeper that is now due. It does not wait for them to run; prefer
    /// ``advance(by:)-(Duration)`` in async tests.
    public func set(_ date: Date) {
        let due: [Sleeper] = state.withLock { state in
            state.now = date
            var due: [Sleeper] = []
            while let sleeper = state.popDue(upTo: date) { due.append(sleeper) }
            state.now = date
            return due
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    /// Moves the clock forward by `duration`, firing due sleepers one at a time in deadline order
    /// and letting each resumed task run (and possibly sleep again) before the next fires.
    public func advance(by duration: Duration) async {
        let target = state.withLock { $0.now.addingTimeInterval(FixedClock.seconds(duration)) }
        await advance(to: target)
    }

    /// Moves the clock forward by `seconds`; see ``advance(by:)-(Duration)``.
    public func advance(by seconds: TimeInterval) async {
        let target = state.withLock { $0.now.addingTimeInterval(seconds) }
        await advance(to: target)
    }

    /// Moves the clock forward to `target` (never backwards); see ``advance(by:)-(Duration)``.
    public func advance(to target: Date) async {
        await FixedClock.yieldToOtherTasks()
        while let sleeper = state.withLock({ $0.popDue(upTo: target) }) {
            sleeper.continuation.resume()
            await FixedClock.yieldToOtherTasks()
        }
        state.withLock { if target > $0.now { $0.now = target } }
        await FixedClock.yieldToOtherTasks()
    }

    /// Advances to each pending deadline until nothing is sleeping (at most `limit` firings, so a
    /// task that sleeps in a loop cannot hang the test). Returns false if sleepers remain.
    @discardableResult
    public func run(limit: Int = 10_000) async -> Bool {
        for _ in 0..<limit {
            await FixedClock.yieldToOtherTasks()
            guard let deadline = nextDeadline else { return true }
            await advance(to: deadline)
        }
        return pendingSleepCount == 0
    }

    /// Yields until at least `count` tasks are sleeping on this clock, so a test can start work
    /// in a `Task` and then advance time deterministically. Returns false if that does not happen
    /// within `maxYields` rounds.
    public func waitForSleepers(_ count: Int = 1, maxYields: Int = 1_000) async -> Bool {
        for _ in 0..<maxYields {
            if pendingSleepCount >= count { return true }
            await FixedClock.yieldToOtherTasks(rounds: 1)
        }
        return pendingSleepCount >= count
    }

    public func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        let (id, deadline, due) = state.withLock { state -> (UInt64, Date, Bool) in
            state.nextID += 1
            let deadline = state.now.addingTimeInterval(FixedClock.seconds(duration))
            let due = deadline <= state.now
            if !due { state.starting[state.nextID] = deadline }
            return (state.nextID, deadline, due)
        }
        if due { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let cancelled = state.withLock { state -> Bool in
                    state.starting[id] = nil
                    if state.cancelledWhileStarting.remove(id) != nil { return true }
                    state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let continuation = state.withLock { state -> CheckedContinuation<Void, any Error>? in
                if let index = state.sleepers.firstIndex(where: { $0.id == id }) {
                    return state.sleepers.remove(at: index).continuation
                }
                if state.starting[id] != nil { state.cancelledWhileStarting.insert(id) }
                return nil
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    static func seconds(_ duration: Duration) -> TimeInterval {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) + Double(attoseconds) / 1e18
    }

    /// Gives other tasks on the cooperative pool a chance to run (resumed sleepers, work started
    /// just before an advance).
    static func yieldToOtherTasks(rounds: Int = 20) async {
        for _ in 0..<rounds {
            await Task.detached(priority: .background) { await Task.yield() }.value
        }
    }
}
