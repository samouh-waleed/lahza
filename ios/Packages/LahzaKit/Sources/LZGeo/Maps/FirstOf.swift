import Synchronization

/// The operation's result, or `onTimeout` thrown after `timeout`, whichever comes first; a cancelled
/// caller gets `CancellationError` at once. The loser is cancelled but not awaited: MapKit's async calls
/// are bridged from completion handlers and ignore cancellation, so waiting for them would defeat the
/// timeout.
func firstOf<T: Sendable>(timeout: Duration, orThrow onTimeout: any Error,
                          _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try Task.checkCancellation()
    let race = Race<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            race.start(continuation)
            race.add(Task {
                do { race.finish(.success(try await operation())) } catch { race.finish(.failure(error)) }
            })
            race.add(Task {
                try? await Task.sleep(for: timeout)
                race.finish(.failure(onTimeout))
            })
        }
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
}

/// Resumes one continuation with the first result it is given, then cancels the tasks still running.
private final class Race<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, any Error>?
        var result: Result<T, any Error>?
        var tasks: [Task<Void, Never>] = []
    }

    private let state = Mutex(State())

    /// Resumes `continuation` with the first result, straight away when it came first (an early cancel).
    func start(_ continuation: CheckedContinuation<T, any Error>) {
        let early = state.withLock { state in
            if state.result == nil { state.continuation = continuation }
            return state.result
        }
        if let early { continuation.resume(with: early) }
    }

    /// Races `task`, which is cancelled when the race is over.
    func add(_ task: Task<Void, Never>) {
        let over = state.withLock { state in
            if state.result == nil { state.tasks.append(task) }
            return state.result != nil
        }
        if over { task.cancel() }
    }

    func finish(_ result: Result<T, any Error>) {
        let winner = state.withLock { state -> (continuation: CheckedContinuation<T, any Error>?, tasks: [Task<Void, Never>])? in
            guard state.result == nil else { return nil }
            state.result = result
            defer { state.continuation = nil; state.tasks = [] }
            return (state.continuation, state.tasks)
        }
        guard let winner else { return }
        winner.continuation?.resume(with: result)
        for task in winner.tasks { task.cancel() }
    }
}
