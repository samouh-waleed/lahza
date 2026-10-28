import LZCore
import LZDesign
import SwiftUI

/// Ask: describe a moment and get back the matching photos. Search is not built yet (template
/// migration E5–E8), so this is the shell: the field, example prompts, the library status (photo
/// access and what Lahza can read) and the privacy promise. It never fakes results.
struct AskScreen: View {
    @State private var query = ""
    @State private var submitted: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LZSpace.xl) {
                VStack(alignment: .leading, spacing: LZSpace.sm) {
                    Text(AskCopy.title).lzText(.displayLarge).foregroundStyle(.lz(.ink))
                    Text(AskCopy.subtitle).lzText(.body).foregroundStyle(.lz(.muted))
                }
                if let submitted {
                    Notice(.info, title: AskCopy.comingSoonTitle, message: AskCopy.comingSoon(submitted))
                }
                VStack(alignment: .leading, spacing: LZSpace.sm) {
                    Text(AskCopy.examplesTitle).lzText(.label).foregroundStyle(.lz(.muted))
                    LZFlowLayout(spacing: LZSpace.sm) {
                        ForEach(AskCopy.examples, id: \.self) { example in
                            LZChip(example, isSelected: query == example) { query = example }
                        }
                    }
                }
                LibraryStatusCard()
                Label(AskCopy.privacy, systemImage: "lock.shield")
                    .lzText(.caption)
                    .foregroundStyle(.lz(.muted))
            }
            .lzPage()
            .padding(.vertical, LZSpace.lg)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(.lz(.bg))
        .navigationTitle(AskCopy.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: AskCopy.prompt)
        .onSubmit(of: .search) { submitted = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : query }
        .onChange(of: query) { _, value in if value.isEmpty { submitted = nil } }
        .accessibilityIdentifier("ask")
    }
}

nonisolated enum AskCopy {
    static let navigationTitle = "Ask Lahza"
    static let title = "What do you remember?"
    static let subtitle = "Describe a moment the way you'd tell a friend. Lahza finds the photos."
    static let prompt = "Soccer at the park last summer…"
    static let examplesTitle = "TRY"
    static let examples = [
        "Playing soccer at the park",
        "Sunsets from my trip",
        "Sushi dinner with family",
        "The hotel receipt",
        "My dog at the beach",
    ]
    static let privacy = "Your photos stay on this iPhone."
    static let comingSoonTitle = "Search is coming soon"
    static func comingSoon(_ query: String) -> String {
        "“\(query)” will search your photos once indexing is ready."
    }
}
