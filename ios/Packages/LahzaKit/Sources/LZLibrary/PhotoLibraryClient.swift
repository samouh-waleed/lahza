import Foundation

/// The PhotoKit surface Lahza uses, as plain values.
///
/// The live implementation is ``LivePhotoLibraryClient``; tests and previews use
/// ``FakePhotoLibraryClient``. ``PhotoAccessStore`` is the only caller in the app. Nothing here may
/// show the iOS permission prompt except ``requestAccess()``.
public protocol PhotoLibraryClient: Sendable {
    /// `PHPhotoLibrary.authorizationStatus(for: .readWrite)`. Never prompts.
    func currentAccess() -> PhotoAccess
    /// `PHPhotoLibrary.requestAuthorization(for: .readWrite)`: shows the iOS prompt while access is
    /// ``PhotoAccess/notDetermined`` and returns the answer; once decided, iOS returns the current
    /// access without asking again.
    func requestAccess() async -> PhotoAccess
    /// How many photos and videos Lahza can read: the whole library or the limited selection, with
    /// the Hidden album left out and the iCloud Shared Library included (decision 14). 0 without
    /// access. Runs off the main actor.
    func readableCount() async -> Int
    /// One event per library change PhotoKit reports, including a new limited selection. Events that
    /// arrive while the last one is still being handled collapse into one.
    func changes() -> AsyncStream<PhotoLibraryChange>
}

/// The library changed (photos added or removed, or a new limited selection). It carries no
/// details yet: the access store only recounts.
public struct PhotoLibraryChange: Sendable, Hashable {
    public init() {}
}
