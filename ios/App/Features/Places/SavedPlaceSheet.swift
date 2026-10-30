import LZDesign
import LZGeo
import LZIndex
import LZSearch
import SwiftUI

/// What the saved-place sheet works on: a new place around a moment's centre (moment detail's Save place), or a place
/// already saved (Settings › Saved places).
nonisolated enum SavedPlaceDraft: Identifiable, Hashable {
    /// `placeLine` is the moment's place ("Al-Nakheel Park · Riyadh"), shown under the title.
    case new(center: Coordinate, placeLine: String?)
    case edit(SavedPlaceRow)

    var id: String {
        switch self {
        case .new(let center, _): "new-\(center.latitude),\(center.longitude)"
        case .edit(let place): "edit-\(place.id)"
        }
    }

    var center: Coordinate {
        switch self {
        case .new(let center, _): center
        case .edit(let place): place.center
        }
    }
}

/// Save place (search spec §7.4), and the same sheet to rename a saved place, change its radius, make it home or
/// delete it: a name, the area [100 m · 250 m · 1 km] with a live count of the photos inside it, Set as Home and Save.
/// The name is the person's own words: never logged.
struct SavedPlaceSheet: View {
    let draft: SavedPlaceDraft
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var radius: Double
    @State private var isHome: Bool
    @State private var count: Int?
    @State private var saving = false
    @State private var failure: String?
    @State private var deletion = SavedPlaceDeletion()
    /// The name field was edited (a problem shows only then, or at Save).
    @State private var touched = false

    init(draft: SavedPlaceDraft) {
        self.draft = draft
        switch draft {
        case .new:
            _name = State(initialValue: "")
            _radius = State(initialValue: SavedPlaceRules.defaultRadius)
            _isHome = State(initialValue: false)
        case .edit(let place):
            _name = State(initialValue: place.name)
            _radius = State(initialValue: SavedPlacesCopy.closestRadius(place.radius))
            _isHome = State(initialValue: place.isHome)
            _touched = State(initialValue: true)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                VStack(alignment: .leading, spacing: LZSpace.xl) {
                    LZTextField(SavedPlacesCopy.nameLabel, text: $name, prompt: SavedPlacesCopy.namePrompt, helper: SavedPlacesCopy.nameHelper,
                                error: touched ? problem : nil, limit: SavedPlaceRules.maxNameLength)
                        .onChange(of: name) { touched = true }
                        .accessibilityIdentifier("saved-place-name")
                    VStack(alignment: .leading, spacing: LZSpace.sm) {
                        Text(SavedPlacesCopy.area)
                            .lzText(.label)
                            .foregroundStyle(.lz(.muted))
                            .accessibilityAddTraits(.isHeader)
                        LZSegmented(SavedPlacesCopy.areaLabel, options: SavedPlaceRules.radii.map { LZChipOption($0, title: SearchFormat.distance($0)) },
                                    selection: $radius)
                            .accessibilityIdentifier("saved-place-radius")
                        Text(SavedPlacesCopy.liveCount(count))
                            .lzText(.subheadline)
                            .foregroundStyle(.lz(.muted))
                            .contentTransition(.numericText())
                            .accessibilityIdentifier("saved-place-count")
                    }
                    LZRowGroup {
                        LZToggleRow(SavedPlacesCopy.setAsHome, subtitle: SavedPlacesCopy.setAsHomeDetail, systemImage: "house", isOn: $isHome)
                            .accessibilityIdentifier("saved-place-home")
                    }
                    if let failure {
                        Notice(.error, message: failure)
                    }
                    LZButton(SavedPlacesCopy.save, systemImage: "checkmark", isLoading: saving, fullWidth: true) { save() }
                        .disabled(problem != nil || !model.savedPlaces.isAvailable)
                        .accessibilityIdentifier("saved-place-save")
                    if case .edit(let place) = draft {
                        LZButton(SavedPlacesCopy.delete, systemImage: "trash", role: .destructive, size: .small) { deletion.ask(place) }
                            .accessibilityIdentifier("saved-place-delete")
                            .confirmsDeletion(of: place, $deletion) { delete($0) }
                    }
                }
                .padding(.horizontal, LZLayout.gutter)
                .padding(.bottom, LZSpace.xl)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .lzSheetPresentation([.large])
        .accessibilityIdentifier("saved-place-sheet")
        .task { await model.savedPlaces.load() }
        .task(id: radius) { count = await model.savedPlaces.count(around: draft.center, radius: radius) }
        .onChange(of: name) { if SavedPlaceRules.isHomeName(name) { isHome = true } }
    }

    @ViewBuilder
    private var header: some View {
        switch draft {
        case .new(_, let placeLine):
            SheetHeader(SavedPlacesCopy.saveTitle, subtitle: placeLine)
        case .edit:
            SheetHeader(SavedPlacesCopy.editTitle)
        }
    }

    /// What is wrong with the name, if anything.
    private var problem: String? {
        let cleaned = SavedPlaceRules.cleaned(name)
        if cleaned.isEmpty { return SavedPlacesCopy.nameEmpty }
        if cleaned.count > SavedPlaceRules.maxNameLength { return SavedPlacesCopy.nameTooLong }
        let editing: Int64? = if case .edit(let place) = draft { place.id } else { nil }
        // "Home" replaces the home picked earlier.
        if !SavedPlaceRules.isHomeName(cleaned), let other = model.savedPlaces.place(named: cleaned, excluding: editing) {
            return SavedPlacesCopy.nameTaken(other.name)
        }
        return nil
    }

    private func save() {
        touched = true
        guard problem == nil, !saving else { return }
        saving = true
        failure = nil
        Task {
            defer { saving = false }
            do {
                switch draft {
                case .new(let center, _):
                    try await model.savedPlaces.save(name: name, center: center, radius: radius, isHome: isHome)
                    model.toasts.show(SavedPlacesCopy.savedToast(SavedPlaceRules.cleaned(name)), systemImage: "mappin.and.ellipse")
                case .edit(let place):
                    try await model.savedPlaces.update(place, name: name, radius: radius, isHome: isHome)
                }
                dismiss()
            } catch let error as SavedPlaceError {
                failure = SavedPlacesCopy.message(error)
            } catch {
                failure = SavedPlacesCopy.writeFailed
            }
        }
    }

    private func delete(_ place: SavedPlaceRow) {
        Task {
            do {
                try await model.savedPlaces.delete(place.id)
                dismiss()
            } catch {
                failure = SavedPlacesCopy.writeFailed
            }
        }
    }
}

/// Deleting a saved place always asks first, from the edit sheet's Delete place or the list's swipe (VoiceOver's
/// delete action is the swipe's): "Delete “My pitch”?" with Delete place, or Cancel to keep it (E21).
nonisolated struct SavedPlaceDeletion: Equatable {
    /// The place being asked about.
    private(set) var asking: Int64?

    mutating func ask(_ place: SavedPlaceRow) { asking = place.id }

    /// Cancel, or the question went away: the place stays.
    mutating func cancel() { asking = nil }

    func isAsking(about place: SavedPlaceRow) -> Bool { asking == place.id }
}

extension View {
    /// The question about `place`, from this view, while `deletion` asks it; Delete place calls `delete`.
    func confirmsDeletion(of place: SavedPlaceRow, _ deletion: Binding<SavedPlaceDeletion>, delete: @escaping (SavedPlaceRow) -> Void) -> some View {
        confirmationDialog(SavedPlacesCopy.deleteTitle(place.name),
                           isPresented: Binding(get: { deletion.wrappedValue.isAsking(about: place) },
                                                set: { if !$0, deletion.wrappedValue.isAsking(about: place) { deletion.wrappedValue.cancel() } }),
                           titleVisibility: .visible) {
            Button(SavedPlacesCopy.delete, role: .destructive) { delete(place) }
        } message: {
            Text(SavedPlacesCopy.deleteMessage)
        }
    }
}
