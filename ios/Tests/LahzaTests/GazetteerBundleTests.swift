import Foundation
import LZGeo
import Testing
@testable import Lahza

/// The offline place list ships inside the app with its dated GeoNames credit, and answers on the iOS runtime.
@Suite struct GazetteerBundleTests {
    @Test func theBundledGazetteerLoadsAndLocatesRiyadh() throws {
        let gazetteer = try Gazetteer.bundled()
        #expect(gazetteer.sourceDate == 20261028)
        let park = gazetteer.locate(Coordinate(latitude: 24.7590, longitude: 46.6440))
        #expect(park.city?.name == "Riyadh")
        #expect(park.timeZone == "Asia/Riyadh")
        #expect(gazetteer.cities(named: "mecca", limit: 1).first?.name == "Makkah")
    }

    @Test func theGeoNamesCreditShipsWithTheApp() throws {
        let url = try #require(Bundle.main.url(forResource: "GeoNames-CC-BY-4.0", withExtension: "txt"))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("creativecommons.org/licenses/by/4.0"))
        // The licence file and the Acknowledgements credit both date the dump the bundled gazetteer comes from.
        let dump = try Gazetteer.bundled().sourceDate
        #expect(text.contains(String(format: "dump of %04d-%02d-%02d", dump / 10_000, dump / 100 % 100, dump % 100)))
        #expect(AcknowledgementsScreen.geoNamesCredit(dumpDate: dump, locale: Locale(identifier: "en_GB"))
            == "Place names · CC BY 4.0 · data as of 28 Oct 2026")
        #expect(AcknowledgementsScreen.geoNamesCredit(dumpDate: nil) == "Place names · CC BY 4.0")
    }
}
