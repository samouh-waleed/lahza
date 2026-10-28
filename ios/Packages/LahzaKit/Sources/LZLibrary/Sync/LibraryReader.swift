import Foundation

/// The photo library as the search index reads it: dated assets newest first in batches, the
/// undated ones, re-reads by id, and what changed since a token (PhotoKit's persistent history).
///
/// ``LiveLibraryReader`` reads PhotoKit through ``LibraryFetchRules``; ``FakeLibraryReader`` is a
/// scripted library for tests and DEBUG launches. Nothing here prompts for access, reads image data
/// or touches the network.
public protocol LibraryReader: Sendable {
    /// The current access. Never prompts.
    func access() -> PhotoAccess
    /// The library's change token now. Take it before a full scan, so the catch-up delta covers
    /// everything that changes while the scan runs.
    func currentToken() throws -> LibraryToken
    /// About how many photos and videos a full scan will read.
    func estimatedCount() async -> Int
    /// Dated assets newest first (creationDate desc). With `frontier`, only creationDate <= frontier.
    /// Calls `handle` once per batch (≤ batchSize) and awaits it (back-pressure). Checks cancellation
    /// between batches; autoreleasepool per batch.
    func scanDated(createdAtOrBefore frontier: Date?, batchSize: Int,
                   _ handle: @Sendable ([LibraryAsset]) async throws -> Void) async throws
    /// Assets with no creation date.
    func scanUndated(batchSize: Int, _ handle: @Sendable ([LibraryAsset]) async throws -> Void) async throws
    /// What changed since `token`.
    func delta(since token: LibraryToken) async -> LibraryDelta
    /// Re-reads by id under the fetch rules. Hidden, deleted or no-longer-shared ids come back missing. Chunks of 500.
    func assets(withIDs ids: [String]) async throws -> [LibraryAsset]
    /// Reports when the library becomes unavailable (PhotoKit's availability observer).
    func availability() -> AsyncStream<LibraryAvailability>
}

/// One photo or video as the index stores it.
public struct LibraryAsset: Sendable, Hashable {
    /// `PHAsset.localIdentifier`.
    public var id: String
    /// Kind, subtypes, dates, coordinate, accuracy, favorite, burst, size and source.
    public var facts: AssetFacts
    /// In the Selfies smart album.
    public var isSelfie: Bool
    public var hasAdjustments: Bool
    /// `PHAsset.adjustmentTimestamp`: the content-edit marker for later passes.
    public var adjustedDate: Date?

    public init(id: String, facts: AssetFacts, isSelfie: Bool = false, hasAdjustments: Bool = false, adjustedDate: Date? = nil) {
        self.id = id
        self.facts = facts
        self.isSelfie = isSelfie
        self.hasAdjustments = hasAdjustments
        self.adjustedDate = adjustedDate
    }
}

/// An opaque point in the library's change history (PhotoKit's `PHPersistentChangeToken`, archived
/// with secure coding). Never logged.
public struct LibraryToken: Sendable, Hashable, Codable {
    public var data: Data

    public init(data: Data) {
        self.data = data
    }
}

/// Why the index has to read the whole library again instead of applying a delta.
public enum FullScanReason: String, Sendable, Codable {
    case firstRun, tokenExpired, detailsUnavailable, historyFailed, undecodableToken, tooManyChanges,
         limitedAccess, accessScopeChanged, libraryUnavailable, rebuild, structureRulesChanged
}

/// What changed since a token.
public enum LibraryDelta: Sendable, Hashable {
    /// Nothing; the token to keep.
    case unchanged(LibraryToken)
    /// Local identifiers that were inserted, updated or deleted, and the token they bring the index up to.
    case changes(inserted: Set<String>, updated: Set<String>, deleted: Set<String>, through: LibraryToken)
    /// The history can't say; read everything again.
    case needsFullScan(FullScanReason)
}

public enum LibraryAvailability: Sendable, Hashable {
    case available, unavailable
}

public enum LibraryReaderError: Error, Sendable, Hashable {
    /// Photo access is not limited or full.
    case noAccess
}
