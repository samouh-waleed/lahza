import Foundation
import Synchronization

/// Hands every value to each subscriber's stream (only the newest when one lags); a new stream starts with the
/// latest value. Finishing ends every stream, and later subscribers get an empty one.
final class Broadcaster<Value: Sendable>: Sendable {
    private struct State {
        var latest: Value
        var continuations: [UUID: AsyncStream<Value>.Continuation] = [:]
        var finished = false
    }

    private let state: Mutex<State>

    init(_ initial: Value) {
        state = Mutex(State(latest: initial))
    }

    var latest: Value { state.withLock { $0.latest } }

    func stream() -> AsyncStream<Value> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Value>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let latest = state.withLock { state -> Value? in
            guard !state.finished else { return nil }
            state.continuations[id] = continuation
            return state.latest
        }
        if let latest {
            continuation.yield(latest)
            continuation.onTermination = { [weak self] _ in
                _ = self?.state.withLock { $0.continuations.removeValue(forKey: id) }
            }
        } else {
            continuation.finish()
        }
        return stream
    }

    func send(_ value: Value) {
        let continuations = state.withLock { state in
            state.latest = value
            return Array(state.continuations.values)
        }
        for continuation in continuations { continuation.yield(value) }
    }

    func finish() {
        let continuations = state.withLock { state in
            state.finished = true
            defer { state.continuations.removeAll() }
            return Array(state.continuations.values)
        }
        for continuation in continuations { continuation.finish() }
    }
}

typealias StatusBroadcaster = Broadcaster<IndexStatus>
