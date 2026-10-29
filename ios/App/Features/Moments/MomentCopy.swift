import Foundation
import LZGeo
import LZIndex

/// Moment and trip words shared by the Moments tab and the detail screens. Dates and times follow the iPhone's region
/// and 12- or 24-hour setting ("Sat 22 Aug 2026" in the UK, "Sat, Aug 22, 2026" in the US), always in the Gregorian
/// calendar, so they agree with the year strip.
nonisolated enum MomentCopy {
    static let navigationTitle = "Moments"
    static let momentTitle = "Moment"
    static let tripTitle = "Trip"
    static let intro = "Your library, grouped into moments."
    static let modeLabel = "Show"
    static let momentsMode = "Moments"
    static let tripsMode = "Trips"
    static let yearsLabel = "Jump to a year"
    static let goneTitle = "This moment changed"
    static let tripGoneTitle = "This trip changed"
    static let goneBody = "Go back to see it again."
    static let unknownPlace = "No location"
    static let readingTitle = "Moments appear as Lahza reads your library"
    static let stillReading = "Lahza is still reading your library. Older moments appear as it goes."
    static let emptyTitle = "No moments yet"
    static let emptyBody = "Photos and videos you take appear here, grouped into moments."
    static let noTripsTitle = "No trips yet"
    static let noTripsBody = "Days away from home, two or more in a row, appear here as trips."
    static let deletedTitle = "Search index deleted"
    static let deletedBody = "Build it again to see your moments."
    static let buildIndex = "Build index"
    static let accessTitle = "Moments need photo access"

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    /// A moment day as its UTC midnight; formatted in UTC, it stays that day everywhere.
    private static func date(_ day: Int32) -> Date { Date(timeIntervalSince1970: TimeInterval(day) * 86_400) }

    private static func dayStyle(_ locale: Locale) -> Date.FormatStyle {
        Date.FormatStyle(locale: locale, calendar: utcCalendar, timeZone: .gmt)
    }

    /// "Sat, 22 Aug 2026" (UK), "Sat, Aug 22, 2026" (US).
    static func dayTitle(_ day: Int32, locale: Locale = .autoupdatingCurrent) -> String {
        date(day).formatted(dayStyle(locale).weekday(.abbreviated).day().month(.abbreviated).year())
    }

    /// "Sat 22 Aug" (UK), "Sat, Aug 22" (US): rows under a month heading.
    static func shortDay(_ day: Int32, locale: Locale = .autoupdatingCurrent) -> String {
        date(day).formatted(dayStyle(locale).weekday(.abbreviated).day().month(.abbreviated))
    }

    /// "Saturday, 22 August 2026", for VoiceOver.
    static func spokenDay(_ day: Int32, locale: Locale = .autoupdatingCurrent) -> String {
        date(day).formatted(dayStyle(locale).weekday(.wide).day().month(.wide).year())
    }

    /// "August 2026".
    static func monthTitle(year: Int, month: Int, locale: Locale = .autoupdatingCurrent) -> String {
        date(LocalTime.day(year: year, month: month, day: 1)).formatted(dayStyle(locale).month(.wide).year())
    }

    /// "August 2026 · 3 moments".
    static func monthHeader(year: Int, month: Int, moments: Int, locale: Locale = .autoupdatingCurrent) -> String {
        "\(monthTitle(year: year, month: month, locale: locale)) · \(count(moments, "moment"))"
    }

    /// "2026 · 41" (the year strip).
    static func yearPill(year: Int, moments: Int) -> String { "\(year) · \(moments.formatted())" }

    static func spokenYear(year: Int, moments: Int) -> String { "\(year), \(count(moments, "moment"))" }

    /// "8 photos · 1 video".
    static func counts(photos: Int, videos: Int) -> String {
        var parts: [String] = []
        if photos > 0 || videos == 0 { parts.append(count(photos, "photo")) }
        if videos > 0 { parts.append(count(videos, "video")) }
        return parts.joined(separator: " · ")
    }

    /// "1 moment", "12 moments".
    static func count(_ value: Int, _ noun: String) -> String {
        value == 1 ? "1 \(noun)" : "\(value.formatted()) \(noun)s"
    }

    /// A row's place: the moment's label, or "No location".
    static func place(_ moment: MomentRow) -> String { moment.label ?? unknownPlace }

    /// "Al-Nakheel Park · Riyadh", adding the country away from home ("Acropolis · Athens · Greece").
    static func placeLine(_ moment: MomentRow, homeCountry: String?) -> String {
        var parts = [moment.label ?? unknownPlace]
        if let city = moment.cityName, city != moment.label { parts.append(city) }
        if let code = moment.countryCode, homeCountry != nil, code != homeCountry {
            let country = CountryNames.name(code)
            if !parts.contains(country) { parts.append(country) }
        }
        return parts.joined(separator: " · ")
    }

    /// "Greece trip" (a row's badge).
    static func tripBadge(_ trip: TripRow) -> String { "\(trip.label) trip" }

    /// "5:00 – 6:40 PM" in the moment's own local time; one time for a single item.
    static func timeSpan(_ moment: MomentRow, locale: Locale = .autoupdatingCurrent) -> String {
        let start = Date(timeIntervalSince1970: TimeInterval(moment.startWall))
        let end = Date(timeIntervalSince1970: TimeInterval(moment.endWall))
        let style = Date.IntervalFormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: utcCalendar, timeZone: .gmt)
        guard end.timeIntervalSince(start) >= 60 else {
            return start.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: utcCalendar, timeZone: .gmt))
        }
        return (start..<end).formatted(style)
    }

    /// "10:00 AM": when the moment started, in its own local time (a trip's rows, under their day).
    static func startTime(_ moment: MomentRow, locale: Locale = .autoupdatingCurrent) -> String {
        Date(timeIntervalSince1970: TimeInterval(moment.startWall))
            .formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: utcCalendar, timeZone: .gmt))
    }

    /// "Athens time" when the moment's zone was on another offset than this iPhone's, else nil.
    static func zoneNote(_ moment: MomentRow, deviceZone: TimeZone) -> String? {
        guard let identifier = moment.timeZone, let zone = TimeZone(identifier: identifier) else { return nil }
        let instant = Date(timeIntervalSince1970: TimeInterval(moment.key.startUTC))
        guard zone.secondsFromGMT(for: instant) != deviceZone.secondsFromGMT(for: instant) else { return nil }
        if identifier.hasPrefix("Etc/") || !identifier.contains("/") {
            return "\(zone.abbreviation(for: instant) ?? identifier) time"
        }
        let city = identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? identifier
        return "\(city) time"
    }

    /// "Greece · 2–8 Jul 2023".
    static func tripTitle(_ trip: TripRow, locale: Locale = .autoupdatingCurrent) -> String {
        "\(trip.label) · \(dayRange(trip.startDay, trip.endDay, locale: locale))"
    }

    /// "2–8 Jul 2023 · 7 days".
    static func tripDates(_ trip: TripRow, locale: Locale = .autoupdatingCurrent) -> String {
        "\(dayRange(trip.startDay, trip.endDay, locale: locale)) · \(count(Int(trip.endDay - trip.startDay) + 1, "day"))"
    }

    /// "75 photos · 1 video · Athens, Mykonos, Oia".
    static func tripCaption(_ trip: TripRow) -> String {
        var parts = [counts(photos: trip.itemCount - trip.videoCount, videos: trip.videoCount)]
        if !trip.places.isEmpty { parts.append(places(trip.places)) }
        return parts.joined(separator: " · ")
    }

    /// At most four names, then "+2".
    static func places(_ names: [String]) -> String {
        let shown = names.prefix(4).joined(separator: ", ")
        return names.count > 4 ? "\(shown) +\(names.count - 4)" : shown
    }

    /// "Fri 7 Jul · Oia" (a trip's day heading: the day and the place of its largest moment).
    static func tripDay(_ day: Int32, moments: [MomentRow]) -> String {
        guard let place = moments.max(by: { $0.itemCount < $1.itemCount })?.label else { return shortDay(day) }
        return "\(shortDay(day)) · \(place)"
    }

    static func allTitle(_ count: Int) -> String { "All · \(count.formatted())" }

    /// "2–8 Jul 2023" (UK), "Jul 2–8, 2023" (US); one date for a single day.
    static func dayRange(_ first: Int32, _ last: Int32, locale: Locale = .autoupdatingCurrent) -> String {
        guard first != last else { return date(first).formatted(dayStyle(locale).day().month(.abbreviated).year()) }
        let style = Date.IntervalFormatStyle(locale: locale, calendar: utcCalendar, timeZone: .gmt).day().month(.abbreviated).year()
        return (date(first)..<date(last)).formatted(style)
    }

    /// "1:05" or "0:42" (a video's length).
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: VoiceOver

    /// "Saturday, 22 August 2026, Al-Nakheel Park, 8 photos, Greece trip".
    static func spokenRow(_ moment: MomentRow, trip: TripRow?) -> String {
        var parts = [spokenDay(moment.key.day), place(moment), counts(photos: moment.photoCount, videos: moment.videoCount)]
        if let trip { parts.append(tripBadge(trip)) }
        return parts.joined(separator: ", ")
    }

    /// "Greece, 2–8 Jul 2023, 7 days, 75 photos, 1 video, Athens, Mykonos, Oia".
    static func spokenTrip(_ trip: TripRow) -> String {
        [trip.label, tripDates(trip).replacingOccurrences(of: " · ", with: ", "), tripCaption(trip).replacingOccurrences(of: " · ", with: ", ")]
            .joined(separator: ", ")
    }
}
