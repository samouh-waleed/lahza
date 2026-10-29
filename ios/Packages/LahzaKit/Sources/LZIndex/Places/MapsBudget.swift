import Foundation
import LZCore

/// The Apple Maps request budget, shared by place naming (background) and search (interactive): a token bucket
/// refilled at `perMinute`, holding at most `capacity`. Background requests leave `interactiveReserve` tokens for
/// search and wait for a token; an interactive request never waits. When Apple Maps throttles, every request
/// stops for 1, 2, 4… up to 30 minutes, until a request succeeds again.
public actor MapsBudget {
    public enum Priority: Sendable {
        case background, interactive
    }

    public let perMinute: Int
    public let capacity: Int
    public let interactiveReserve: Int
    private let clock: any AppClock
    private var tokens: Double
    private var refilled: Date
    private var throttles = 0
    /// Requests wait until then after Apple Maps throttled.
    public private(set) var backoffUntil: Date?

    static let maxBackoffMinutes = 30.0

    public init(perMinute: Int = 30, capacity: Int = 5, interactiveReserve: Int = 2, clock: any AppClock) {
        self.perMinute = max(1, perMinute)
        self.capacity = max(1, capacity)
        self.interactiveReserve = min(max(0, interactiveReserve), max(0, capacity - 1))
        self.clock = clock
        tokens = Double(self.capacity)
        refilled = clock.now
    }

    /// Takes a token. Background waits for one above the interactive reserve (and for any backoff to end), then
    /// returns true; it throws `CancellationError` when cancelled. Interactive returns false at once when the
    /// bucket is empty or Apple Maps asked to back off.
    public func acquire(_ priority: Priority) async throws -> Bool {
        switch priority {
        case .interactive:
            refill()
            if let backoffUntil, backoffUntil > clock.now { return false }
            guard tokens >= 1 else { return false }
            tokens -= 1
            return true
        case .background:
            while true {
                try Task.checkCancellation()
                refill()
                if let backoffUntil, backoffUntil > clock.now {
                    try await clock.sleep(for: .seconds(backoffUntil.timeIntervalSince(clock.now)))
                    continue
                }
                let floor = Double(interactiveReserve) + 1
                if tokens >= floor {
                    tokens -= 1
                    return true
                }
                // Until the bucket climbs back above the reserve.
                try await clock.sleep(for: .seconds((floor - tokens) * 60 / Double(perMinute)))
            }
        }
    }

    /// Apple Maps throttled a request: back off for 1, 2, 4… up to 30 minutes from now.
    public func reportThrottled() {
        throttles += 1
        let minutes = min(Self.maxBackoffMinutes, pow(2, Double(throttles - 1)))
        backoffUntil = clock.now.addingTimeInterval(minutes * 60)
    }

    /// A request went through: the backoff starts over.
    public func reportSuccess() {
        throttles = 0
        backoffUntil = nil
    }

    /// Restores a backoff saved before a relaunch (the index keeps it in `meta`).
    public func restoreBackoff(until date: Date?) {
        guard let date, date > clock.now, date > (backoffUntil ?? .distantPast) else { return }
        backoffUntil = date
        throttles = max(throttles, 1)
    }

    /// Tokens now (tests, the inspector).
    public var available: Double {
        refill()
        return tokens
    }

    private func refill() {
        let now = clock.now
        let elapsed = max(0, now.timeIntervalSince(refilled))
        tokens = min(Double(capacity), tokens + elapsed * Double(perMinute) / 60)
        refilled = now
    }
}
