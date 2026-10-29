import LZDesign
import LZGeo
import LZIndex
import LZSearch
import SwiftUI

/// Settings › Saved places (search spec §7.3): home first (the estimate, a place set as home, or none) with Change…,
/// then the places the person named. A place opens its sheet (rename, radius, home, delete); a swipe deletes it.
struct SavedPlacesScreen: View {
    @Environment(AppModel.self) private var model
    @State private var editing: SavedPlaceDraft?
    @State private var choosingHome = false
    @State private var failure: String?

    var body: some View {
        let store = model.savedPlaces
        Group {
            if store.isAvailable {
                List {
                    Text(SavedPlacesCopy.intro)
                        .lzText(.body)
                        .foregroundStyle(.lz(.muted))
                        .row(separator: false)
                        .padding(.top, LZSpace.lg)
                    Section {
                        ListRow(SavedPlacesCopy.homeTitle, subtitle: SavedPlacesCopy.homeSubtitle(store.home), systemImage: "house",
                                value: SavedPlacesCopy.homeValue(store.home, city: model.index.status.summary?.homeCityName))
                            .row(separator: false)
                            .accessibilityIdentifier("saved-places-home")
                        LZButton(SavedPlacesCopy.change, systemImage: "arrow.triangle.2.circlepath", role: .secondary, size: .small) { choosingHome = true }
                            .row(separator: false)
                            .padding(.bottom, LZSpace.md)
                            .accessibilityIdentifier("saved-places-change-home")
                    } header: {
                        header(SavedPlacesCopy.homeSection)
                    }
                    .listSectionSeparator(.hidden)
                    Section {
                        if store.places.isEmpty, store.hasLoaded {
                            Text(SavedPlacesCopy.empty)
                                .lzText(.subheadline)
                                .foregroundStyle(.lz(.muted))
                                .row(separator: false)
                                .padding(.vertical, LZSpace.sm)
                        }
                        ForEach(store.places) { place in
                            ListRow(place.name, subtitle: SavedPlacesCopy.placeSubtitle(place, photos: store.photoCounts[place.id]),
                                    systemImage: place.isHome ? "house" : "mappin.and.ellipse", accessory: .chevron) { editing = .edit(place) }
                                .row(separator: true)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(SavedPlacesCopy.deleteShort, systemImage: "trash", role: .destructive) { delete(place) }
                                        .tint(Color.lz(.danger))
                                }
                                .accessibilityIdentifier("saved-place-row")
                        }
                        if let failure {
                            Notice(.error, message: failure)
                                .row(separator: false)
                        }
                        Text(SavedPlacesCopy.footer)
                            .lzText(.caption)
                            .foregroundStyle(.lz(.muted))
                            .row(separator: false)
                            .padding(.vertical, LZSpace.lg)
                    } header: {
                        header(SavedPlacesCopy.placesSection)
                    }
                    .listSectionSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 0)
            } else {
                // After Delete index the index can be built from here; without photo access Photo access says how.
                let deleted = model.index.status.phase == .off(.deletedByUser)
                EmptyState(SavedPlacesCopy.offTitle, message: SavedPlacesCopy.offMessage, systemImage: "mappin.slash", tone: .neutral,
                           actionTitle: deleted ? IndexCopy.buildIndex : nil, action: deleted ? { model.index.buildAgain() } : nil)
                    .lzPage()
                    .frame(maxHeight: .infinity)
            }
        }
        .background(.lz(.bg))
        .tint(Color.lz(.accent))
        .navigationTitle(SavedPlacesCopy.screenTitle)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("saved-places")
        .sheet(item: $editing) { SavedPlaceSheet(draft: $0) }
        .sheet(isPresented: $choosingHome) { HomePickerSheet() }
        .task(id: model.index.version) { await store.load() }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .lzText(.label)
            .foregroundStyle(.lz(.muted))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, LZSpace.md)
            .padding(.bottom, LZSpace.xs)
            .padding(.horizontal, LZLayout.gutter)
            .background(.lz(.bg))
            .listRowInsets(EdgeInsets())
            .accessibilityAddTraits(.isHeader)
    }

    private func delete(_ place: SavedPlaceRow) {
        failure = nil
        Task {
            do {
                try await model.savedPlaces.delete(place.id)
            } catch {
                failure = SavedPlacesCopy.writeFailed
            }
        }
    }
}

private extension View {
    /// A row of the saved-places list on the page's paper, inside its gutters, with or without a hairline under it.
    func row(separator: Bool) -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: LZLayout.gutter, bottom: 0, trailing: LZLayout.gutter))
            .listRowBackground(Color.clear)
            .listRowSeparator(separator ? .visible : .hidden)
            .listRowSeparatorTint(Color.lz(.line))
    }
}

/// Home › Change…: the places where photos are taken at night (most nights first, the estimate marked) and No home.
struct HomePickerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [HomeCandidate] = []
    @State private var loaded = false
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        let home = model.savedPlaces.home
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(SavedPlacesCopy.pickerTitle, subtitle: SavedPlacesCopy.pickerSubtitle)
                VStack(alignment: .leading, spacing: LZSpace.xl) {
                    VStack(alignment: .leading, spacing: LZSpace.sm) {
                        Text(SavedPlacesCopy.nightPlaces)
                            .lzText(.label)
                            .foregroundStyle(.lz(.muted))
                            .accessibilityAddTraits(.isHeader)
                        if loaded, candidates.isEmpty {
                            Text(SavedPlacesCopy.noCandidates)
                                .lzText(.subheadline)
                                .foregroundStyle(.lz(.muted))
                        }
                        LZRowGroup {
                            ForEach(candidates) { candidate in
                                let current = SavedPlacesCopy.isCurrent(candidate, home: home)
                                ListRow(candidate.name ?? SavedPlacesCopy.unnamed, subtitle: SavedPlacesCopy.candidateSubtitle(candidate, among: candidates),
                                        value: SavedPlacesCopy.nights(candidate.nights), accessory: current ? .checkmark : .none, isLoading: working && !current) {
                                    if !current { choose(candidate.isEstimate ? .estimated : .point(candidate.center)) }
                                }
                                .accessibilityIdentifier("home-candidate")
                            }
                        }
                    }
                    LZRowGroup {
                        ListRow(SavedPlacesCopy.noHomeTitle, subtitle: SavedPlacesCopy.noHomeDetail, systemImage: "house.slash",
                                accessory: home == .noHome ? .checkmark : .none) {
                            if home != .noHome { choose(.noHome) }
                        }
                        .accessibilityIdentifier("home-none")
                    }
                    if let failure {
                        Notice(.error, message: failure)
                    }
                }
                .padding(.horizontal, LZLayout.gutter)
                .padding(.bottom, LZSpace.xl)
            }
        }
        // Large: No home sits under the night places.
        .lzSheetPresentation([.large])
        .accessibilityIdentifier("home-picker")
        .task {
            candidates = await model.savedPlaces.homeCandidates()
            loaded = true
        }
    }

    private func choose(_ choice: HomeChoice) {
        guard !working else { return }
        working = true
        failure = nil
        Task {
            defer { working = false }
            do {
                try await model.savedPlaces.setHome(choice)
                dismiss()
            } catch {
                failure = SavedPlacesCopy.writeFailed
            }
        }
    }
}

/// The saved places' words (search spec §7.3, §7.4).
nonisolated enum SavedPlacesCopy {
    static let screenTitle = "Saved places"
    static let intro = "Name the places you go back to, then search them by name, like “at my pitch”."
    static let homeSection = "HOME"
    static let placesSection = "YOUR PLACES"
    static let homeTitle = "Home"
    static let change = "Change…"
    static let empty = "No saved places yet. Open a moment and tap Save place to name where it was."
    static let footer = "Saved places live in the search index on this iPhone. Rebuilding the index keeps them; deleting it removes them."
    static let offTitle = "Saved places need the search index"
    static let offMessage = "Saved places live in the index on this iPhone. Once it’s built, save places from your moments."
    static let deleteShort = "Delete"
    static let writeFailed = "Couldn’t change your saved places. Try again."

    // MARK: Home picker

    static let pickerTitle = "Home"
    static let pickerSubtitle = "Lahza uses your home to tell trips from days around town."
    static let nightPlaces = "WHERE YOU TAKE PHOTOS AT NIGHT"
    static let estimate = "Estimated"
    static let unnamed = "Unnamed area"
    static let noHomeTitle = "No home"
    static let noHomeDetail = "Lahza doesn’t group trips"
    static let noCandidates = "Lahza hasn’t seen enough night photos to suggest a place."

    // MARK: Sheet

    static let saveTitle = "Save place"
    static let saveHint = "Names the area around this moment, so you can search it by name"
    static let editTitle = "Edit place"
    static let nameLabel = "Name"
    static let namePrompt = "My pitch"
    static let nameHelper = "Search it by this name."
    static let area = "AREA"
    static let areaLabel = "How far around it"
    static let setAsHome = "Set as Home"
    static let setAsHomeDetail = "Lahza uses your home to tell trips from days around town"
    static let save = "Save"
    static let delete = "Delete place"
    static let deleteMessage = "Its moments go back to their own place names. Your photos aren’t touched."
    static let nameEmpty = "Give the place a name."
    static let nameTooLong = "Use \(SavedPlaceRules.maxNameLength) characters or fewer."

    /// Settings' row value: how many places are saved.
    @MainActor static func settingsValue(_ store: SavedPlacesStore) -> String? {
        store.places.isEmpty ? nil : store.places.count.formatted()
    }

    static func homeSubtitle(_ home: HomeSetting) -> String {
        switch home {
        case .estimated(.some): "Estimated from where you take photos at night"
        case .estimated: "Not worked out yet. Lahza needs about 10 nights of photos in one place."
        case .saved(let place): SavedPlaceRules.isHomeName(place.name) ? "Set by you" : "\(place.name) · set by you"
        case .noHome: "None. Lahza doesn’t group trips."
        }
    }

    /// The home's city: the estimate's, or that of the place set as home (so the row says where home is).
    static func homeValue(_ home: HomeSetting, city: String?) -> String? {
        switch home {
        case .estimated(.some), .saved: city
        case .estimated(nil), .noHome: nil
        }
    }

    /// "Estimated" on the estimate. A place named like another row says how far and which way it is from the estimate
    /// (or the row with the most nights), so the two can be told apart: "12 km north of your estimated home".
    static func candidateSubtitle(_ candidate: HomeCandidate, among candidates: [HomeCandidate]) -> String? {
        if candidate.isEstimate { return estimate }
        guard candidates.contains(where: { $0.id != candidate.id && $0.name == candidate.name }),
              let reference = candidates.first(where: \.isEstimate) ?? candidates.first, reference.id != candidate.id else { return nil }
        let name = reference.isEstimate ? "your estimated home"
            : reference.name == candidate.name ? "the \(reference.name ?? unnamed) above" : reference.name ?? unnamed
        let metres = reference.center.distance(to: candidate.center)
        guard metres >= 50 else { return "Next to \(name)" }
        return "\(SearchFormat.distance(metres)) \(compass(from: reference.center, to: candidate.center)) of \(name)"
    }

    /// The eight-point compass direction from one place to another ("northeast").
    static func compass(from start: Coordinate, to end: Coordinate) -> String {
        let lat1 = start.latitude * .pi / 180, lat2 = end.latitude * .pi / 180, dLon = (end.longitude - start.longitude) * .pi / 180
        let bearing = atan2(sin(dLon) * cos(lat2), cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)) * 180 / .pi
        let directions = ["north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest"]
        return directions[Int(((bearing + 360).truncatingRemainder(dividingBy: 360) / 45).rounded()) % 8]
    }

    /// "Within 250 m · 85 photos", and "Home" first when it is the home.
    static func placeSubtitle(_ place: SavedPlaceRow, photos: Int?) -> String {
        ([place.isHome ? "Home" : nil, "Within \(SearchFormat.distance(place.radius))"] + [photos.map { MomentCopy.count($0, "photo") }])
            .compactMap { $0 }.joined(separator: " · ")
    }

    static func isCurrent(_ candidate: HomeCandidate, home: HomeSetting) -> Bool {
        switch home {
        case .estimated(let base): base.map { $0.tile == candidate.tile } ?? false
        case .saved(let place): GeoHash.encode(place.center, precision: 6) == candidate.tile
        case .noHome: false
        }
    }

    /// "48 nights".
    static func nights(_ count: Int) -> String { count == 1 ? "1 night" : "\(count.formatted()) nights" }

    /// "This area has 85 of your photos".
    static func liveCount(_ count: Int?) -> String {
        switch count {
        case nil: "Counting your photos here…"
        case 0?: "None of your photos are in this area yet"
        case let count?: "This area has \(count.formatted()) of your photos"
        }
    }

    static func nameTaken(_ name: String) -> String { "You already have a place called “\(name)”." }

    static func deleteTitle(_ name: String) -> String { "Delete “\(name)”?" }

    static func savedToast(_ name: String) -> String { "Saved “\(name)”" }

    static func message(_ error: SavedPlaceError) -> String {
        switch error {
        case .emptyName: nameEmpty
        case .nameTaken: "You already have a place with that name."
        case .notFound: "That place is gone."
        }
    }

    /// The radius choice nearest `metres` (a place saved before the choices changed shows the closest one).
    static func closestRadius(_ metres: Double) -> Double {
        SavedPlaceRules.radii.min { abs($0 - metres) < abs($1 - metres) } ?? SavedPlaceRules.defaultRadius
    }
}
