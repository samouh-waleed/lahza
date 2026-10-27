import DDCore
import DDDesign
import SwiftUI

struct PrivacySettingsScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Your photos") {
                Text("Your photos never leave this iPhone.").font(.headline)
                Text("When library search arrives, Lahza will read your photo library on this device to build its search index. The index, and anything Lahza learns about your photos, will be stored only here, excluded from backups, and deletable from Settings.")
                Text("There’s no account, no Lahza server, no ads and no tracking.")
            }
            Section("What leaves the device") {
                Text("Lahza Plus: at launch, Lahza checks your Plus status with RevenueCat, which manages App Store purchases. RevenueCat receives an anonymous ID and your purchase status, never your photos.")
                Text("Place names (coming with search): to turn a place like “Al-Nakheel Park” into a location, Lahza will ask Apple Maps. Apple receives the place name or an approximate location, never your photos.")
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
