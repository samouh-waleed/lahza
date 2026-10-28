import Foundation

/// English country names from ISO codes, and back from what people type ("uae", "ksa", "holland").
public enum CountryNames {
    private static let english = Locale(identifier: "en_US")

    /// Common names Locale doesn't give, folded.
    private static let synonyms: [String: [String]] = [
        "AE": ["uae", "emirates", "the emirates"],
        "SA": ["ksa", "saudi", "saudia"],
        "US": ["us", "usa", "america", "united states of america", "the us", "the usa"],
        "GB": ["uk", "britain", "great britain", "england", "scotland", "wales", "northern ireland", "the uk"],
        "NL": ["holland", "the netherlands"],
        "TR": ["turkey"],
        "CZ": ["czech republic"],
        "CI": ["ivory coast"],
        "MM": ["burma"],
        "CD": ["drc", "dr congo"],
        "KR": ["korea"],
        "KP": ["north korea"],
        "PS": ["palestine"],
        "VA": ["vatican", "vatican city"],
        "MK": ["macedonia"],
        "SZ": ["swaziland"],
        "CV": ["cape verde"],
        "TL": ["east timor"],
        "HK": ["hong kong"],
        "MO": ["macau", "macao"],
        "BA": ["bosnia"],
        "PH": ["the philippines"],
    ]

    /// Folded name → codes. Each English name also contributes its "&" → "and" and "St." → "Saint"
    /// forms, both sides of a parenthesis and the part before " - " ("Myanmar (Burma)" → `myanmar`,
    /// `burma`; "Congo - Kinshasa" → `congo`).
    private static let index: [String: [String]] = {
        var index: [String: [String]] = [:]
        func add(_ key: String, _ code: String) {
            guard !key.isEmpty, index[key]?.contains(code) != true else { return }
            index[key, default: []].append(code)
        }
        for region in Locale.Region.isoRegions {
            let code = region.identifier
            guard code.count == 2, code.allSatisfy(\.isLetter), let name = english.localizedString(forRegionCode: code) else { continue }
            var forms = [name, name.replacingOccurrences(of: "&", with: "and"), name.replacingOccurrences(of: "St. ", with: "Saint ")]
            if let open = name.range(of: " ("), let close = name.range(of: ")", range: open.upperBound..<name.endIndex) {
                forms += [String(name[..<open.lowerBound]), String(name[open.upperBound..<close.lowerBound])]
            }
            if let dash = name.range(of: " - ") { forms.append(String(name[..<dash.lowerBound])) }
            for form in forms { add(PlaceNames.fold(form), code) }
        }
        for (code, names) in synonyms.sorted(by: { $0.key < $1.key }) {
            for name in names { add(PlaceNames.fold(name), code) }
        }
        return index
    }()

    /// "United Arab Emirates" for "AE"; the code itself if Locale has no name for it.
    public static func name(_ code: String) -> String {
        english.localizedString(forRegionCode: code) ?? code
    }

    /// The ISO codes whose English name, a part of it, or a common synonym folds to `folded`
    /// (pass ``PlaceNames/fold(_:)`` output). Several codes when the name is shared ("congo").
    public static func codes(matching folded: String) -> [String] {
        index[folded]?.sorted() ?? []
    }
}
