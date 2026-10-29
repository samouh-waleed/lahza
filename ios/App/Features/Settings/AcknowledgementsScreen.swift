import LZDesign
import LZGeo
import SwiftUI

/// Third-party software, fonts and data, with their licence texts bundled in the app as the licences
/// require (for CC BY data, the attribution and a link to the licence). New entries land as the matching
/// features do: SigLIP 2 (Apache-2.0, with its NOTICE).
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
        Entry(name: "GRDB", licence: "MIT License", url: "https://github.com/groue/GRDB.swift", file: "GRDB-LICENSE"),
        Entry(name: "RevenueCat purchases-ios", licence: "MIT License", url: "https://github.com/RevenueCat/purchases-ios", file: "RevenueCat-LICENSE"),
    ]
    private let fonts = [
        Entry(name: "Instrument Serif", licence: "SIL Open Font License 1.1", url: "https://fonts.google.com/specimen/Instrument+Serif", file: "OFL-InstrumentSerif"),
        Entry(name: "Newsreader", licence: "SIL Open Font License 1.1", url: "https://fonts.google.com/specimen/Newsreader", file: "OFL-Newsreader"),
    ]

    /// The offline place list (LZGeo's gazetteer).
    private let data = [
        Entry(name: "GeoNames", licence: Self.bundledGeoNamesCredit, url: "https://www.geonames.org", file: "GeoNames-CC-BY-4.0"),
    ]

    /// Dated from the bundled gazetteer, so a `make gazetteer` rebuild updates it.
    private static let bundledGeoNamesCredit = geoNamesCredit(dumpDate: (try? Gazetteer.bundled())?.sourceDate)

    /// "Place names · CC BY 4.0 · data as of 28 Oct 2026" for the GeoNames dump of a yyyymmdd `dumpDate`.
    static func geoNamesCredit(dumpDate: Int?, locale: Locale = .current) -> String {
        let credit = "Place names · CC BY 4.0"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        guard let dumpDate,
              let date = calendar.date(from: DateComponents(year: dumpDate / 10_000, month: dumpDate / 100 % 100, day: dumpDate % 100))
        else { return credit }
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: .gmt).day().month(.abbreviated).year()
        return "\(credit) · data as of \(date.formatted(style))"
    }

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
