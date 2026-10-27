import Foundation
import Synchronization

/// A scripted ``PhotoLibraryClient`` for tests, previews and the DEBUG `-LZPhotos` launch argument.
/// It never touches PhotoKit. Every call is recorded in ``calls``; the starting access, the answer to
/// the prompt and the counts are scripted, and a test can change access (as iPhone Settings would)
/// or emit a library change.
public final class FakePhotoLibraryClient: PhotoLibraryClient {
    /// A recorded call.
    public enum Call: Sendable, Equatable {
        case currentAccess
        case requestAccess
        case readableCount
    }

    private struct State {
        var access: PhotoAccess
        var answer: PhotoAccess
        var counts: [PhotoAccess: Int]
        var calls: [Call] = []
        var prompts = 0
        var beforeAnswer: @Sendable () async -> Void = {}
        var beforeCount: @Sendable () async -> Void = {}
        var continuations: [UUID: AsyncStream<PhotoLibraryChange>.Continuation] = [:]
    }

    private let state: Mutex<State>

    /// Sample library sizes: a full library and a small limited selection.
    public static let sampleCounts: [PhotoAccess: Int] = [.full: 12_480, .limited: 36]

    /// A library whose access starts at `access`, whose prompt answers `answer`, and which holds
    /// `counts` readable photos and videos at each access.
    public init(access: PhotoAccess = .notDetermined, answer: PhotoAccess = .full, counts: [PhotoAccess: Int] = FakePhotoLibraryClient.sampleCounts) {
        state = Mutex(State(access: access, answer: answer, counts: counts))
    }

    // MARK: Test controls

    /// Every call so far, in order.
    public var calls: [Call] { state.withLock { $0.calls } }
    /// How many times the iOS prompt would have shown (only while access was not determined).
    public var prompts: Int { state.withLock { $0.prompts } }
    /// How many ``changes()`` streams are subscribed (a test waits for one before emitting).
    public var changeSubscriberCount: Int { state.withLock { $0.continuations.count } }
    /// The readable count scripted for `access`.
    public func count(for access: PhotoAccess) -> Int { state.withLock { $0.counts[access] ?? 0 } }

    /// Changes access without a prompt, as iPhone Settings would.
    public func setAccess(_ access: PhotoAccess) {
        state.withLock { $0.access = access }
    }

    /// Sets the answer the next prompt gives.
    public func setAnswer(_ answer: PhotoAccess) {
        state.withLock { $0.answer = answer }
    }

    /// Sets the readable count at `access`.
    public func setCount(_ count: Int, for access: PhotoAccess) {
        state.withLock { $0.counts[access] = count }
    }

    /// Runs `gate` inside every ``requestAccess()`` before it answers, so a test can hold the prompt open.
    public func setBeforeAnswer(_ gate: @escaping @Sendable () async -> Void) {
        state.withLock { $0.beforeAnswer = gate }
    }

    /// Runs `gate` inside every ``readableCount()`` after it has counted and before it returns, so a
    /// test can hold a slow count in flight.
    public func setBeforeCount(_ gate: @escaping @Sendable () async -> Void) {
        state.withLock { $0.beforeCount = gate }
    }

    /// Clears the call log.
    public func resetCalls() {
        state.withLock { $0.calls.removeAll() }
    }

    /// Publishes a library change to every ``changes()`` stream.
    public func emitChange() {
        let continuations = state.withLock { Array($0.continuations.values) }
        for continuation in continuations { continuation.yield(PhotoLibraryChange()) }
    }

    // MARK: PhotoLibraryClient

    public func currentAccess() -> PhotoAccess {
        state.withLock {
            $0.calls.append(.currentAccess)
            return $0.access
        }
    }

    public func requestAccess() async -> PhotoAccess {
        let gate = state.withLock {
            $0.calls.append(.requestAccess)
            return $0.beforeAnswer
        }
        await gate()
        // Like iOS: the prompt shows only while access is not determined.
        return state.withLock {
            if $0.access == .notDetermined {
                $0.prompts += 1
                $0.access = $0.answer
            }
            return $0.access
        }
    }

    public func readableCount() async -> Int {
        // Counted at the call, like a fetch that started before access changed.
        let (count, gate) = state.withLock {
            $0.calls.append(.readableCount)
            return ($0.access.canRead ? $0.counts[$0.access] ?? 0 : 0, $0.beforeCount)
        }
        await gate()
        return count
    }

    public func changes() -> AsyncStream<PhotoLibraryChange> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<PhotoLibraryChange>.makeStream(bufferingPolicy: .bufferingNewest(1))
        state.withLock { $0.continuations[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.continuations.removeValue(forKey: id) }
        }
        return stream
    }
}
