import LZDesign
import LZSearch
import SwiftUI

/// One "Understood as" chip: a slot as search read it (search spec §7.1). A searched query's chips open their editor.
nonisolated struct QueryChipModel: Identifiable, Hashable {
    var id: Int
    var kind: SlotKind
    var title: String
    var systemImage: String
    /// False for words Lahza can't search yet ("soccer · not yet"), which show as a pill that explains itself.
    var isSupported: Bool
    /// The place is being looked up (the chip spins).
    var isLoading = false

    /// The chips of a searched query.
    static func chips(_ query: ResolvedQuery) -> [QueryChipModel] {
        ordered(query.slots.map { slot in
            QueryChipModel(id: slot.id, kind: slot.slot.kind, title: slot.isSupported ? slot.chip : AskCopy.notYet(slot.chip, kind: slot.slot.kind),
                           systemImage: slot.systemImage, isSupported: slot.isSupported)
        })
    }

    /// The chips of a query not searched yet (typing, or still searching), from its words; the place spins while it is
    /// looked up. Words that only might be a place show as a place until search says otherwise.
    static func chips(_ parsed: ParsedQuery, lookingUpPlace: Bool = false) -> [QueryChipModel] {
        ordered(parsed.slots.map { slot in
            let supported = SearchCapabilities.v0.supports(slot.value)
            let words = slot.value.phrase()
            let symbol: String = switch slot.value {
            case .place: "mappin"
            case .time: "calendar"
            case .media(let media): media.kinds == [.video] ? "film" : "photo"
            case .event: "airplane"
            case .people, .visual, .text: "info.circle"
            }
            return QueryChipModel(id: slot.id, kind: slot.kind, title: supported ? AskCopy.capitalized(words) : AskCopy.notYet(words, kind: slot.kind),
                                  systemImage: symbol, isSupported: supported, isLoading: lookingUpPlace && slot.kind == .place)
        })
    }

    /// What search understood first, then the words it can't search yet ("soccer · not yet"), each in word order;
    /// VoiceOver reads them in the same order.
    private static func ordered(_ chips: [QueryChipModel]) -> [QueryChipModel] {
        chips.filter(\.isSupported) + chips.filter { !$0.isSupported }
    }

    /// "Place, Al-Nakheel Park"; "soccer, not searchable yet" (VoiceOver adds "button" and the edit hint when it edits).
    var accessibilityLabel: String {
        guard isSupported else { return "\(title.replacingOccurrences(of: AskCopy.notYetSuffix, with: "")), \(AskCopy.notSearchableYet)" }
        return "\(AskCopy.slotName(kind)), \(title)"
    }
}

/// "UNDERSTOOD AS" and the query's chips, wrapping. With `edit`, a tap opens the chip's editor; without (while typing
/// or searching), the chips only show what was understood.
struct UnderstoodAsRow: View {
    let chips: [QueryChipModel]
    var edit: ((Int) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: LZSpace.xs) {
            Text(AskCopy.understoodAs)
                .lzText(.label)
                .foregroundStyle(.lz(.muted))
                .accessibilityAddTraits(.isHeader)
            GlassEffectContainer(spacing: LZSpace.sm) {
                LZFlowLayout(spacing: LZSpace.sm, lineSpacing: 0) {
                    ForEach(chips) { QueryChip(chip: $0, edit: edit) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask-understood-as")
    }
}

/// A slot chip (glass, with the slot's symbol), or for words Lahza can't search yet a neutral pill. A searched chip
/// opens its editor (the unsupported one says why and offers Remove); while typing, a slot chip only shows and the
/// pill explains itself in a popover.
struct QueryChip: View {
    let chip: QueryChipModel
    var edit: ((Int) -> Void)?
    @State private var explains = false

    var body: some View {
        if chip.isSupported, let edit, !chip.isLoading {
            LZChip(chip.title, systemImage: chip.systemImage, isSelected: false) { edit(chip.id) }
                .accessibilityLabel(chip.accessibilityLabel)
                .accessibilityHint(AskCopy.editHint)
                .accessibilityIdentifier("ask-chip-\(chip.kind.rawValue)")
        } else if chip.isSupported {
            LZChip(chip.title, systemImage: chip.systemImage, isSelected: false, isLoading: chip.isLoading) {}
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(chip.accessibilityLabel)
                .accessibilityValue(chip.isLoading ? AskCopy.lookingUpValue : "")
                .accessibilityRemoveTraits(.isButton)
                .accessibilityIdentifier("ask-chip-\(chip.kind.rawValue)")
        } else {
            Button { if let edit { edit(chip.id) } else { explains = true } } label: {
                Pill(chip.title, systemImage: "info.circle", tone: .neutral)
                    .lzHitTarget()
            }
            .buttonStyle(LZPressStyle(scale: 0.96))
            .accessibilityLabel(chip.accessibilityLabel)
            .accessibilityHint(edit == nil ? AskCopy.unsupportedHint : AskCopy.unsupportedEditHint)
            .accessibilityIdentifier("ask-chip-\(chip.kind.rawValue)")
            .popover(isPresented: $explains) {
                Text(AskCopy.unsupportedExplanation(chip.kind))
                    .lzText(.subheadline)
                    .foregroundStyle(.lz(.ink))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 280, alignment: .leading)
                    .padding(LZSpace.lg)
                    .presentationCompactAdaptation(.popover)
            }
        }
    }
}

/// "Which Salam Park?" with a chip per candidate ("Riyadh · 10"); the one searched is ticked. A tap searches the
/// other place and remembers the choice.
struct PlacePickerRow: View {
    let picker: PlacePicker
    let choose: (PlacePicker.Choice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LZSpace.xs) {
            Text(picker.question)
                .lzText(.headline)
                .foregroundStyle(.lz(.ink))
                .accessibilityAddTraits(.isHeader)
            GlassEffectContainer(spacing: LZSpace.sm) {
                LZFlowLayout(spacing: LZSpace.sm, lineSpacing: 0) {
                    ForEach(picker.choices) { choice in
                        LZChip(choice.label, systemImage: "mappin", isSelected: choice.id == picker.chosen) {
                            if choice.id != picker.chosen { choose(choice) }
                        }
                        .accessibilityLabel(AskCopy.spokenChoice(choice))
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask-picker")
    }
}

/// "TRY" and searches the library can answer, each with its count ("Al-Nakheel Park · 85"); a tap searches it.
struct ExampleSearchesRow: View {
    let examples: [ExampleSearch]
    let search: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LZSpace.xs) {
            Text(AskCopy.tryLabel)
                .lzText(.label)
                .foregroundStyle(.lz(.muted))
                .accessibilityAddTraits(.isHeader)
            GlassEffectContainer(spacing: LZSpace.sm) {
                LZFlowLayout(spacing: LZSpace.sm, lineSpacing: 0) {
                    ForEach(examples) { example in
                        LZChip(AskCopy.example(example), systemImage: "magnifyingglass", isSelected: false) { search(example.text) }
                            .accessibilityLabel(AskCopy.spokenExample(example))
                            .accessibilityHint(AskCopy.exampleHint)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask-examples")
    }
}
