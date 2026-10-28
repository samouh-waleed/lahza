import Foundation
import Synchronization

/// A scripted ``MapsClient`` for tests, previews and DEBUG launches: answers from a fixed table, logs
/// every call, and can be made to fail (throttled, offline) once or until cleared.
public final class FakeMapsClient: MapsClient {
    /// What the fake knows.
    public struct Table: Sendable, Hashable {
        /// Answers for ``pointsOfInterest(near:radius:categories:)``: those within the radius whose
        /// category is asked for, nearest first.
        public var places: [MapPlace]
        /// Answers for ``reverseGeocode(_:)``: the nearest within ``addressReach``.
        public var addresses: [ScriptedAddress]
        /// Answers for ``search(_:near:)``, keyed by the folded query text.
        public var searches: [String: [MapPlace]]
        /// Metres.
        public var addressReach: Double

        public init(places: [MapPlace] = [], addresses: [ScriptedAddress] = [], searches: [String: [MapPlace]] = [:],
                    addressReach: Double = 5_000) {
            self.places = places
            self.addresses = addresses
            self.searches = Dictionary(searches.map { (PlaceNames.fold($0.key), $0.value) }, uniquingKeysWith: +)
            self.addressReach = addressReach
        }

        public static let empty = Table()
    }

    public struct ScriptedAddress: Sendable, Hashable {
        public var coordinate: Coordinate
        public var address: MapAddress

        public init(_ coordinate: Coordinate, _ address: MapAddress) {
            self.coordinate = coordinate
            self.address = address
        }
    }

    public enum Call: Sendable, Hashable {
        case pointsOfInterest(Coordinate, radius: Double, categories: Set<PlaceCategory>)
        case reverseGeocode(Coordinate)
        case search(String, GeoRegion?)
    }

    private struct State {
        var calls: [Call] = []
        var nextFailures: [MapsError] = []
        var failure: MapsError?
    }

    public let table: Table
    private let latency: Duration
    private let state = Mutex(State())

    /// `latency` is slept before every answer (the app's DEBUG launches use about 150 ms; tests use none).
    public init(_ table: Table = .empty, latency: Duration = .zero) {
        self.table = table
        self.latency = latency
    }

    /// Every call so far, oldest first (failed ones included).
    public var calls: [Call] { state.withLock { $0.calls } }

    /// Makes every later call throw `error` (e.g. `.throttled`, `.offline`) until it is set back to nil.
    public func setFailure(_ error: MapsError?) {
        state.withLock { $0.failure = error }
    }

    /// Makes the next calls throw these errors, one per call, before any ``setFailure(_:)`` error applies.
    public func failNext(_ errors: MapsError...) {
        state.withLock { $0.nextFailures += errors }
    }

    public func pointsOfInterest(near c: Coordinate, radius: Double, categories: Set<PlaceCategory>) async throws(MapsError) -> [MapPlace] {
        try await begin(.pointsOfInterest(c, radius: radius, categories: categories))
        let found = table.places
            .filter { (categories.isEmpty || categories.contains($0.category)) && $0.coordinate.distance(to: c) <= radius }
            .sorted { $0.coordinate.distance(to: c) < $1.coordinate.distance(to: c) }
        guard !found.isEmpty else { throw .notFound }
        return found
    }

    public func reverseGeocode(_ c: Coordinate) async throws(MapsError) -> MapAddress? {
        try await begin(.reverseGeocode(c))
        let nearest = table.addresses
            .filter { $0.coordinate.distance(to: c) <= table.addressReach }
            .min { $0.coordinate.distance(to: c) < $1.coordinate.distance(to: c) }
        guard let nearest else { throw .notFound }
        return nearest.address
    }

    public func search(_ text: String, near region: GeoRegion?) async throws(MapsError) -> [MapPlace] {
        try await begin(.search(text, region))
        guard let found = table.searches[PlaceNames.fold(text)], !found.isEmpty else { throw .notFound }
        return found
    }

    private func begin(_ call: Call) async throws(MapsError) {
        let failure = state.withLock { state -> MapsError? in
            state.calls.append(call)
            return state.nextFailures.isEmpty ? state.failure : state.nextFailures.removeFirst()
        }
        if latency > .zero {
            do { try await Task.sleep(for: latency) } catch { throw .cancelled }
        }
        if let failure { throw failure }
    }
}
