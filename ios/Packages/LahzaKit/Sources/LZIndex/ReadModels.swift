import Foundation
import LZGeo

/// A moment's stable key for the UI: its day and first capture second. Row ids can change when a day is
/// segmented again; the key only changes when the moment itself does.
public struct MomentKey: Sendable, Hashable, Codable {
    public var day: Int32
    public var startUTC: Int64

    public init(day: Int32, startUTC: Int64) {
        self.day = day
        self.startUTC = startUTC
    }
}

/// Which moments a page lists.
public struct MomentFilter: Sendable, Hashable {
    /// Only moments whose local day falls in this year.
    public var year: Int?
    /// Only the moments of this trip.
    public var tripID: Int64?

    public init(year: Int? = nil, tripID: Int64? = nil) {
        self.year = year
        self.tripID = tripID
    }

    public static let all = MomentFilter()
}

/// One moment as lists show it.
public struct MomentRow: Sendable, Hashable, Identifiable {
    public var id: Int64
    public var key: MomentKey
    public var endUTC: Int64
    /// Local wall seconds (``LocalTime``) of the first and last item.
    public var startWall: Int64
    public var endWall: Int64
    /// The IANA zone of the moment's first item.
    public var timeZone: String?
    public var itemCount: Int
    public var photoCount: Int
    public var videoCount: Int
    public var locatedCount: Int
    /// Items whose position is borrowed from a located item of the moment.
    public var borrowedCount: Int
    /// The label place's name (saved place, home, park, locality, city or country).
    public var label: String?
    public var cityName: String?
    /// ISO 3166 alpha-2.
    public var countryCode: String?
    public var tripID: Int64?
    public var coverLocalID: String?
}

/// One trip as lists show it.
public struct TripRow: Sendable, Hashable, Identifiable {
    public var id: Int64
    public var startDay: Int32
    public var endDay: Int32
    public var label: String
    public var countryCode: String?
    /// The trip's country is not the home country.
    public var abroad: Bool
    public var momentCount: Int
    public var itemCount: Int
    public var videoCount: Int
    /// The farthest distance from home, in km.
    public var maxKm: Double
    public var coverLocalID: String?
}

/// A moment and its items in time order.
public struct MomentDetailRows: Sendable, Hashable {
    public struct Member: Sendable, Hashable, Identifiable {
        public var id: Int64
        public var localID: String
        public var isVideo: Bool
        public var utc: Int64?
        public var wall: Int64?
        public var duration: Double
        public var isFavorite: Bool
        /// The position comes from a located item of the moment.
        public var hasBorrowedLocation: Bool
    }

    public var moment: MomentRow
    public var members: [Member]
}

/// The home base of one local year.
public struct HomeBaseRow: Sendable, Hashable {
    public enum Source: Int, Sendable, Hashable {
        case estimated = 0, inherited = 1, user = 2
    }

    public var year: Int
    public var center: Coordinate
    /// Geohash-6 of the winning tile.
    public var tile: String
    public var timeZone: String?
    public var countryCode: String?
    /// Distinct moment days with night photos in the tile.
    public var nights: Int
    public var source: Source
}

/// How many moments a local month holds.
public struct MonthCount: Sendable, Hashable, Identifiable {
    public var year: Int
    public var month: Int
    public var moments: Int

    /// yyyymm.
    public var id: Int { year * 100 + month }

    public init(year: Int, month: Int, moments: Int) {
        self.year = year
        self.month = month
        self.moments = moments
    }
}
