import Foundation
import Synchronization

/// One queue for every store operation: each operation starts only after the previous one settled,
/// whatever its outcome.
///
/// A plain `actor` would not do: an actor lets another call in while one is suspended at an await,
/// so a RevenueCat `logIn` could interleave with a purchase. Operations run in unstructured tasks, so
/// a caller that stops waiting (a price deadline, a cancelled screen task) never releases the queue
/// early: the operation keeps its place until it settles.
final class SerialQueue: Sendable {
    private let tail = Mutex<Task<Void, Never>?>(nil)

    init() {}

    /// Appends `operation` and returns its task. Enqueueing is synchronous, so two calls made in
    /// order run in that order.
    func enqueue<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) -> Task<T, any Error> {
        tail.withLock { tail in
            let previous = tail
            let task = Task<T, any Error> {
                await previous?.value
                return try await operation()
            }
            tail = Task { _ = await task.result }
            return task
        }
    }
}

/// Resolves exactly once: the first of several racing producers wins, later ones are ignored.
final class OneShot<Value: Sendable>: Sendable {
    private let state = Mutex<(continuation: CheckedContinuation<Value, any Error>?, result: Result<Value, any Error>?)>((nil, nil))

    init() {}

    /// Waits for the first ``resolve(_:)``. Call once.
    func wait(onCancel: @escaping @Sendable () -> Void = {}) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let ready = state.withLock { state -> Result<Value, any Error>? in
                    if let result = state.result { return result }
                    state.continuation = continuation
                    return nil
                }
                if let ready { continuation.resume(with: ready) }
            }
        } onCancel: {
            onCancel()
            self.resolve(.failure(CancellationError()))
        }
    }

    /// Settles the waiter; only the first call counts.
    func resolve(_ result: Result<Value, any Error>) {
        let continuation = state.withLock { state -> CheckedContinuation<Value, any Error>?? in
            guard state.result == nil else { return nil }
            state.result = result
            defer { state.continuation = nil }
            return .some(state.continuation)
        }
        if case .some(.some(let continuation)) = continuation { continuation.resume(with: result) }
    }
}
