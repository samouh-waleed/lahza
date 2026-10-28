import LZDesign
import SwiftUI

struct AppearanceSettingsScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: Binding(get: { model.appearance }, set: { model.setAppearance($0) })) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Appearance")
            } footer: {
                Text("Match iPhone follows your iPhone’s light and dark setting.")
            }
        }
        .settingsForm("Appearance")
        .accessibilityIdentifier("appearance-settings")
    }
}
