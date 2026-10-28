import DDCore
import Foundation
import Observation

/// Photo access and how many photos and videos Lahza can read. The app refreshes it at launch and
/// whenever it returns to the foreground (people change access in iPhone Settings); ``start()``
/// follows library changes, such as a new limited selection. Lahza never blocks on the answer:
/// every screen works without access and points to iPhone Settings.
@MainActor @Observable public final class PhotoAccessStore {
    public private(set) var access: PhotoAccess
    /// How many photos and videos Lahza can read: nil until counted, 0 without access.
    public private(set) var readableCount: Int?
    /// The iOS prompt is up.
    public private(set) var isRequesting = false

    @ObservationIgnored private let client: any PhotoLibraryClient
    @ObservationIgnored private var changes: Task<Void, Never>?
    /// Bumped by every refresh, so a slow count never overwrites a newer answer.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let log = Log("library")

    /// Reads the current access (never prompts); the count waits for ``refresh()``.
    public init(client: any PhotoLibraryClient) {
        self.client = client
        access = client.currentAccess()
    }

    /// Re-reads access and, when Lahza can read, recounts off the main actor.
    public func refresh() async {
        await startRefresh()?.value
    }

    /// Shows the iOS prompt when access is not determined and returns the answer (any answer is
    /// fine). Once access is decided it never asks again and returns the current access: only iPhone
    /// Settings changes it. It returns as soon as the prompt does; the recount carries on behind
    /// (``readableCount`` stays nil until it lands), so onboarding never waits on a large library.
    @discardableResult
    public func request() async -> PhotoAccess {
        apply(client.currentAccess())
        guard access.canAsk, !isRequesting else { return access }
        isRequesting = true
        let answer = await client.requestAccess()
        isRequesting = false
        apply(answer)
        startRefresh()
        return access
    }

    /// Follows library changes (photos added or removed, a new limited selection) and recounts.
    /// Calling it again does nothing.
    public func start() {
        guard changes == nil else { return }
        let stream = client.changes()
        changes = Task { [weak self] in
            for await _ in stream {
                await self?.refresh()
            }
        }
    }

    /// Stops following library changes.
    public func stop() {
        changes?.cancel()
        changes = nil
    }

    /// Re-reads access now and, when Lahza can read, starts the recount and returns it (nil when
    /// there is nothing to count).
    @discardableResult
    private func startRefresh() -> Task<Void, Never>? {
        generation += 1
        let current = generation
        apply(client.currentAccess())
        guard access.canRead else {
            readableCount = 0
            return nil
        }
        return Task { [client] in
            let count = await client.readableCount()
            guard current == generation else { return }
            readableCount = count
        }
    }

    private func apply(_ latest: PhotoAccess) {
        guard latest != access else { return }
        log.info("Photo access: \(access.rawValue) → \(latest.rawValue)", privacy: .public)
        access = latest
        // The old count belongs to the old access.
        readableCount = nil
    }
}
