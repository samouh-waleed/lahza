import LZCore
import LZDesign
import SwiftUI

struct PrivacySettingsScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Your photos") {
                Text(PrivacyCopy.headline).font(.headline)
                Text(PrivacyCopy.library)
                Text(PrivacyCopy.index)
                Text(PrivacyCopy.noServer)
            }
            Section("What leaves the device") {
                Text(PrivacyCopy.purchases)
                Text(PrivacyCopy.appleMaps)
            }
            Section {
                if let url = model.dependencies.environment.privacyURL { Link("Privacy policy", destination: url) }
                if let url = model.dependencies.environment.termsURL { Link("Terms of use", destination: url) }
            }
        }
        .settingsForm("Privacy")
        .accessibilityIdentifier("privacy-settings")
    }
}

/// Settings › Privacy's words (search spec §7.3, §11.3).
nonisolated enum PrivacyCopy {
    static let headline = "Your photos never leave this iPhone."
    static let library = "With the access you choose, Lahza reads your photo library on this device, never your Hidden album."
    static let index = "Lahza keeps a search index on this iPhone: the dates, places, moments and trips it learns from your photos. It is stored only here, excluded from backups, deleted if you turn photo access off, and you can delete it in Settings › Search index."
    static let noServer = "There’s no account, no Lahza server, no ads and no tracking."
    static let purchases = "Lahza Plus: at launch, Lahza checks your Plus status with RevenueCat, which manages App Store purchases. RevenueCat receives an anonymous ID and your purchase status, never your photos."
    static let appleMaps = "Apple Maps place names: to name places like parks, Lahza sends Apple Maps the approximate location of groups of your photos, and the places you type when you search. Apple receives a location or a place name, never your photos. Turn it off in Settings › Search index."
}
