import Foundation
import Network
import Synchronization

/// Whether the network is reachable, and when that changes: place naming waits for it instead of failing.
public protocol NetworkStatus: Sendable {
    var isReachable: Bool { get }
    /// A fresh stream per subscriber, starting with the current value and keeping only the newest.
    func changes() -> AsyncStream<Bool>
}

/// ``NetworkStatus`` over `NWPathMonitor`.
public final class LiveNetworkStatus: NetworkStatus {
    private let monitor = NWPathMonitor()
    private let broadcaster: Broadcaster<Bool>

    public init() {
        broadcaster = Broadcaster(monitor.currentPath.status == .satisfied)
        monitor.pathUpdateHandler = { [broadcaster] path in
            let reachable = path.status == .satisfied
            if reachable != broadcaster.latest { broadcaster.send(reachable) }
        }
        monitor.start(queue: DispatchQueue(label: "com.waleedsamouh.lahza.network", qos: .utility))
    }

    deinit {
        monitor.cancel()
        broadcaster.finish()
    }

    public var isReachable: Bool { broadcaster.latest }

    public func changes() -> AsyncStream<Bool> { broadcaster.stream() }
}

/// A scripted ``NetworkStatus`` for tests and DEBUG launches.
public final class FakeNetworkStatus: NetworkStatus {
    private let broadcaster: Broadcaster<Bool>

    public init(reachable: Bool) {
        broadcaster = Broadcaster(reachable)
    }

    public var isReachable: Bool { broadcaster.latest }

    public func setReachable(_ reachable: Bool) {
        broadcaster.send(reachable)
    }

    public func changes() -> AsyncStream<Bool> { broadcaster.stream() }
}
