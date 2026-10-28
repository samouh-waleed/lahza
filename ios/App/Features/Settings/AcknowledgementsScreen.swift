import LZDesign
import SwiftUI

/// Third-party software, fonts and data, with their full licence texts (bundled in the app, as the
/// licences require). New entries land as the matching features do: SigLIP 2 (Apache-2.0, with its
/// NOTICE) and GRDB (MIT).
struct AcknowledgementsScreen: View {
    private struct Entry: Identifiable {
        let name: String
        let licence: String
        let url: String
        /// The bundled licence file (name without extension, `.txt`).
        let file: String
        var id: String { name }
    }

    private let software = [
        Entry(name: "RevenueCat purchases-ios", licence: "MIT License", url: "https://github.com/RevenueCat/purchases-ios", file: "RevenueCat-LICENSE"),
    ]
    private let fonts = [
        Entry(name: "Instrument Serif", licence: "SIL Open Font License 1.1", url: "https://fonts.google.com/specimen/Instrument+Serif", file: "OFL-InstrumentSerif"),
        Entry(name: "Newsreader", licence: "SIL Open Font License 1.1", url: "https://fonts.google.com/specimen/Newsreader", file: "OFL-Newsreader"),
    ]

    /// The offline place list (LZGeo's gazetteer).
    private let data = [
        Entry(name: "GeoNames", licence: "Place names · Creative Commons Attribution 4.0 (CC BY 4.0)", url: "https://www.geonames.org",
              file: "GeoNames-CC-BY-4.0"),
    ]

    var body: some View {
        List {
            Section {
                Text("Lahza is built with the help of these projects.")
            }
            Section("Software") { ForEach(software) { row($0) } }
            Section("Fonts") { ForEach(fonts) { row($0) } }
            Section("Data") { ForEach(data) { row($0) } }
        }
        .settingsForm("Acknowledgements")
        .accessibilityIdentifier("acknowledgements")
    }

    private func row(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let link = URL(string: entry.url) { Link(entry.name, destination: link) } else { Text(entry.name) }
            Text(entry.licence).font(.footnote).foregroundStyle(.secondary)
            if let text = Self.licenceText(entry.file) {
                DisclosureGroup("Licence text") {
                    Text(text).font(.caption.monospaced()).textSelection(.enabled)
                }
                .font(.footnote)
            }
        }
    }

    private static func licenceText(_ file: String) -> String? {
        guard let url = Bundle.main.url(forResource: file, withExtension: "txt") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
