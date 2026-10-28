import Foundation
#if canImport(Photos)
import Photos
#endif

/// What Lahza may do with the photo library, at PhotoKit's read-write level (the only level with a
/// limited selection).
public enum PhotoAccess: String, CaseIterable, Sendable, Hashable {
    /// iOS has not asked yet.
    case notDetermined
    /// Screen Time or a device-management profile blocks access; the person cannot change it.
    case restricted
    /// The person said no (or turned access off in iPhone Settings).
    case denied
    /// Only the photos the person picked.
    case limited
    /// The whole library.
    case full

    /// Lahza can read photos (the whole library or the picked ones).
    public var canRead: Bool { self == .limited || self == .full }

    /// The iOS prompt can still be shown. iOS shows it once; after that only iPhone Settings changes it.
    public var canAsk: Bool { self == .notDetermined }

    /// The person can change access in iPhone Settings (it is decided and not blocked).
    public var canChangeInSettings: Bool { self != .restricted && self != .notDetermined }
}

#if canImport(Photos)
extension PhotoAccess {
    public init(_ status: PHAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .restricted: self = .restricted
        case .denied: self = .denied
        case .limited: self = .limited
        case .authorized: self = .full
        // A status from a newer iOS: treat it as no access until Lahza knows what it means.
        @unknown default: self = .denied
        }
    }
}
#endif
