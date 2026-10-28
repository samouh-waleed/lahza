import LZDesign
import LZLibrary
import SwiftUI
import UIKit

/// Ask's library card: what Lahza can read, and the one next step for each photo access. Lahza
/// works without access; the card says why it matters and points to iPhone Settings.
struct LibraryStatusCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        let store = model.photoAccess
        let access = store.access
        PaperCard {
            VStack(alignment: .leading, spacing: LZSpace.md) {
                HStack(alignment: .top, spacing: LZSpace.md) {
                    IconBadge(access.symbol, tone: access.tone)
                    VStack(alignment: .leading, spacing: LZSpace.xs) {
                        Text(PhotoAccessCopy.cardTitle(access, count: store.readableCount))
                            .lzText(.headline)
                            .foregroundStyle(.lz(.ink))
                        Text(PhotoAccessCopy.cardBody(access))
                            .lzText(.subheadline)
                            .foregroundStyle(.lz(.muted))
                    }
                }
                actions(access, isRequesting: store.isRequesting)
            }
        }
        .accessibilityIdentifier("library-status")
    }

    @ViewBuilder
    private func actions(_ access: PhotoAccess, isRequesting: Bool) -> some View {
        switch access {
        case .notDetermined:
            // Straight to the iOS prompt (covers installs that finished onboarding before it asked).
            LZButton(PhotoAccessCopy.continueToPrompt, size: .small, isLoading: isRequesting) {
                Task { await model.photoAccess.request() }
            }
            .accessibilityIdentifier("library-continue")
        case .limited:
            LZAdaptiveStack(spacing: LZSpace.sm) {
                LZButton(PhotoAccessCopy.choosePhotos, role: .secondary, size: .small) {
                    Task { await model.chooseLimitedPhotos() }
                }
                .accessibilityIdentifier("library-choose-photos")
                LZButton(PhotoAccessCopy.openSettings, role: .quiet, size: .small) { openURL.openAppSettings() }
                    .accessibilityIdentifier("library-open-settings")
            }
        case .denied:
            LZButton(PhotoAccessCopy.openSettings, role: .secondary, size: .small) { openURL.openAppSettings() }
                .accessibilityIdentifier("library-open-settings")
        case .full, .restricted:
            EmptyView()
        }
    }
}

extension OpenURLAction {
    /// Lahza's page in iPhone Settings, where photo access is changed.
    func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        callAsFunction(url)
    }
}

extension PhotoAccess {
    /// The glyph Ask's card and the Settings screen show.
    var symbol: String {
        switch self {
        case .notDetermined: "photo.on.rectangle.angled"
        case .full: "photo.stack"
        case .limited: "photo.badge.checkmark"
        case .denied: "eye.slash"
        case .restricted: "lock"
        }
    }

    var tone: LZTone {
        switch self {
        case .notDetermined, .limited: .accent
        case .full: .sage
        case .denied, .restricted: .neutral
        }
    }
}

/// Photo access wording, shared by Ask, Settings and onboarding. Numbers follow the iPhone's region.
nonisolated enum PhotoAccessCopy {
    static let continueToPrompt = "Continue"
    static let choosePhotos = "Choose photos"
    static let openSettings = "Open Settings"
    static let screenTitle = "Photo access"
    static let libraryNote = "Lahza skips your Hidden album and includes your iCloud Shared Library. Photos are read only on this iPhone."

    /// The short status (the Settings row's value).
    static func status(_ access: PhotoAccess) -> String {
        switch access {
        case .full: "Full"
        case .limited: "Limited"
        case .denied: "Off"
        case .notDetermined: "Not set"
        case .restricted: "Restricted"
        }
    }

    /// "12,480 photos and videos".
    static func photosAndVideos(_ count: Int, locale: Locale = .autoupdatingCurrent) -> String {
        let number = count.formatted(.number.locale(locale))
        return count == 1 ? "\(number) photo or video" : "\(number) photos and videos"
    }

    /// "You've shared 36 photos and videos" (the same count, so the same words as the full library).
    static func shared(_ count: Int, locale: Locale = .autoupdatingCurrent) -> String {
        count == 0 ? "You haven’t shared any photos yet" : "You’ve shared \(photosAndVideos(count, locale: locale))"
    }

    // MARK: Ask's card

    static func cardTitle(_ access: PhotoAccess, count: Int?) -> String {
        switch access {
        case .notDetermined: "Lahza needs photo access"
        case .full: count.map { $0 == 0 ? "Your photo library is empty" : photosAndVideos($0) } ?? "Counting your photos…"
        case .limited: count.map { shared($0) } ?? "You’ve shared some photos"
        case .denied: "Photo access is off"
        case .restricted: "Photo access is restricted on this iPhone"
        }
    }

    static func cardBody(_ access: PhotoAccess) -> String {
        switch access {
        case .notDetermined: "Lahza reads your photos on this iPhone to search them. Continue, and iOS asks for access."
        case .full: "Search indexing arrives in a later update and will cover your whole library."
        case .limited: "When search arrives, it covers only what you share. Choose more, or turn on full access in iPhone Settings."
        case .denied: "Lahza can’t search your photos without it. Turn it on in iPhone Settings."
        case .restricted: "Screen Time or an organisation’s profile blocks it."
        }
    }

    // MARK: Settings and onboarding

    static func headline(_ access: PhotoAccess) -> String {
        switch access {
        case .full: "Full access"
        case .limited: "Limited access"
        case .denied: "Access is off"
        case .notDetermined: "Not set yet"
        case .restricted: "Restricted"
        }
    }

    static func detail(_ access: PhotoAccess, count: Int?) -> String {
        switch access {
        case .full:
            count.flatMap { $0 > 0 ? "Lahza can read your whole library on this iPhone: \(photosAndVideos($0))." : nil }
                ?? "Lahza can read your whole library on this iPhone."
        case .limited:
            switch count {
            case nil: "Lahza can read only the photos and videos you choose."
            case 0?: "Lahza can read only the photos and videos you choose. You haven’t chosen any yet."
            case let count?: "Lahza can read only the photos and videos you choose (\(count.formatted(.number)) so far)."
            }
        case .denied:
            "Lahza can’t read your photos, so it can’t search them. Turn access on in iPhone Settings."
        case .notDetermined:
            "Lahza hasn’t asked yet. Continue, and iOS asks for access."
        case .restricted:
            "Screen Time or an organisation’s profile blocks photo access on this iPhone, so it can’t be changed here."
        }
    }
}
