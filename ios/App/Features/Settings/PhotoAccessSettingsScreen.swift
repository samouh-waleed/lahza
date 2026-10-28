import LZDesign
import LZLibrary
import SwiftUI

/// Settings › Photo access: the current access, what it means, the next step and what Lahza reads.
/// iOS owns the choice itself: its prompt once, then iPhone Settings.
struct PhotoAccessSettingsScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        let store = model.photoAccess
        let access = store.access
        Form {
            Section {
                Label(PhotoAccessCopy.headline(access), systemImage: access.symbol)
                    .font(.headline)
                    .accessibilityIdentifier("photo-access-status")
                Text(PhotoAccessCopy.detail(access, count: store.readableCount)).foregroundStyle(.secondary)
            }
            if access.canAsk || access.canChangeInSettings {
                Section {
                    if access.canAsk {
                        // Straight to the iOS prompt.
                        Button(PhotoAccessCopy.continueToPrompt) { Task { await store.request() } }
                            .disabled(store.isRequesting)
                            .accessibilityIdentifier("photo-access-continue")
                    }
                    if access == .limited {
                        Button(PhotoAccessCopy.choosePhotos) { Task { await model.chooseLimitedPhotos() } }
                            .accessibilityIdentifier("photo-access-choose")
                    }
                    if access.canChangeInSettings {
                        Button(PhotoAccessCopy.openSettings) { openURL.openAppSettings() }
                            .accessibilityIdentifier("photo-access-open-settings")
                    }
                }
            }
            Section("What Lahza reads") {
                Text(PhotoAccessCopy.libraryNote)
            }
        }
        .settingsForm(PhotoAccessCopy.screenTitle)
        .accessibilityIdentifier("photo-access-settings")
    }
}
