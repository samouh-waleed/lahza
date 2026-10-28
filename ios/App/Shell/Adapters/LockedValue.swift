import Synchronization

/// A value several executors read synchronously (widget sources, notification sources) while the
/// main actor writes it.
nonisolated final class LockedValue<Value: Sendable>: Sendable {
    private let storage: Mutex<Value>

    init(_ value: Value) { storage = Mutex(value) }

    var value: Value {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }

    func set(_ value: Value) { storage.withLock { $0 = value } }

    /// Changes the value in place, atomically.
    func mutate(_ change: (inout Value) -> Void) { storage.withLock { change(&$0) } }
}
