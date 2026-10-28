import DDCore
import DDDesign
import SwiftUI

/// Ask: describe a moment and get back the matching photos. Search is not built yet (template
/// migration E5–E8), so this is the shell: the field, example prompts, the library status and the
/// privacy promise. It never fakes results.
struct AskScreen: View {
    @State private var query = ""
    @State private var submitted: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DDSpace.xl) {
                VStack(alignment: .leading, spacing: DDSpace.sm) {
                    Text(AskCopy.title).ddText(.displayLarge).foregroundStyle(.dd(.ink))
                    Text(AskCopy.subtitle).ddText(.body).foregroundStyle(.dd(.muted))
                }
                if let submitted {
                    Notice(.info, title: AskCopy.comingSoonTitle, message: AskCopy.comingSoon(submitted))
                }
                VStack(alignment: .leading, spacing: DDSpace.sm) {
                    Text(AskCopy.examplesTitle).ddText(.label).foregroundStyle(.dd(.muted))
                    DDFlowLayout(spacing: DDSpace.sm) {
                        ForEach(AskCopy.examples, id: \.self) { example in
                            DDChip(example, isSelected: query == example) { query = example }
                        }
                    }
                }
                PaperCard {
                    HStack(alignment: .top, spacing: DDSpace.md) {
                        IconBadge("photo.stack", tone: .accent)
                        VStack(alignment: .leading, spacing: DDSpace.xs) {
                            Text(AskCopy.libraryTitle).ddText(.headline).foregroundStyle(.dd(.ink))
                            Text(AskCopy.libraryBody).ddText(.subheadline).foregroundStyle(.dd(.muted))
                        }
                    }
                }
                Label(AskCopy.privacy, systemImage: "lock.shield")
                    .ddText(.caption)
                    .foregroundStyle(.dd(.muted))
            }
            .ddPage()
            .padding(.vertical, DDSpace.lg)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(.dd(.bg))
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
    static let libraryTitle = "Your library isn't indexed yet"
    static let libraryBody = "Photo access and on-device indexing arrive in the next milestone. Your photos will never leave your iPhone."
    static let privacy = "Your photos stay on this iPhone."
    static let comingSoonTitle = "Search is coming soon"
    static func comingSoon(_ query: String) -> String {
        "“\(query)” will search your photos once indexing is ready."
    }
}
