#if DEBUG
import LZDesign
import LZLibrary
import SwiftUI

/// Settings › Developer › Library census, in DEBUG builds only: Phase 0 spike S2 on this iPhone.
/// It reads photo metadata, samples local thumbnails (network off) and shows aggregate numbers with
/// the S2 pass marks. The plain-text report leaves the iPhone only if the person shares it. The run
/// lives in ``AppModel/censusRunner``, so it carries on if the screen is left.
struct LibraryCensusScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let runner = model.censusRunner
        let store = model.photoAccess
        ScrollView {
            VStack(alignment: .leading, spacing: LZSpace.xl) {
                VStack(alignment: .leading, spacing: LZSpace.sm) {
                    Text(LibraryCensusCopy.title).lzText(.displayLarge).foregroundStyle(.lz(.ink))
                    Text(LibraryCensusCopy.subtitle).lzText(.body).foregroundStyle(.lz(.muted))
                }
                CensusIntroCard()
                if store.access.canRead {
                    if store.access == .limited {
                        Notice(.info, title: LibraryCensusCopy.limitedTitle, message: LibraryCensusCopy.limited(store.readableCount))
                    }
                    CensusRunPanel(runner: runner)
                    // The last results stay through a new run and come back if it's cancelled or fails.
                    if !runner.phase.isRunning, let report = runner.report {
                        CensusResults(report: report)
                    }
                } else {
                    Notice(.warn, title: LibraryCensusCopy.needsAccessTitle, message: LibraryCensusCopy.needsAccess(store.access),
                           actionTitle: LibraryCensusCopy.photoAccessLink) { model.open(.photoAccess) }
                        .accessibilityIdentifier("library-census-needs-access")
                }
            }
            .lzPage()
            .padding(.vertical, LZSpace.lg)
        }
        .background(.lz(.bg))
        .tint(Color.lz(.accent))
        .navigationTitle(LibraryCensusCopy.screenTitle)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("library-census")
        // Auto-Lock would suspend Lahza mid-run and make the timings include the pause.
        .onChange(of: runner.phase.isRunning, initial: true) { _, running in
            UIApplication.shared.isIdleTimerDisabled = running
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

/// What the census measures and what it never shows.
private struct CensusIntroCard: View {
    var body: some View {
        PaperCard {
            VStack(alignment: .leading, spacing: LZSpace.md) {
                HStack(alignment: .top, spacing: LZSpace.md) {
                    IconBadge("chart.bar.doc.horizontal", tone: .accent)
                    VStack(alignment: .leading, spacing: LZSpace.xs) {
                        Text(LibraryCensusCopy.introTitle).lzText(.headline).foregroundStyle(.lz(.ink))
                        Text(LibraryCensusCopy.introBody).lzText(.subheadline).foregroundStyle(.lz(.muted))
                    }
                }
                VStack(alignment: .leading, spacing: LZSpace.sm) {
                    ForEach(LibraryCensusCopy.measures, id: \.self) { item in
                        Label(item, systemImage: "checkmark.circle")
                            .lzText(.subheadline)
                            .foregroundStyle(.lz(.ink))
                    }
                }
                Label(LibraryCensusCopy.privacy, systemImage: "lock.shield")
                    .lzText(.caption)
                    .foregroundStyle(.lz(.muted))
            }
        }
        .accessibilityIdentifier("library-census-intro")
    }
}

/// Run, or the running stage with its progress and Cancel; how the last run ended.
private struct CensusRunPanel: View {
    let runner: CensusRunner

    var body: some View {
        let phase = runner.phase
        if phase.isRunning {
            PaperCard {
                VStack(alignment: .leading, spacing: LZSpace.md) {
                    Text(LibraryCensusCopy.step(phase.stage ?? 1)).lzText(.label).foregroundStyle(.lz(.muted))
                    if let progress = runner.progress {
                        ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))) {
                            Text(LibraryCensusCopy.stageName(phase))
                        } currentValueLabel: {
                            Text(LibraryCensusCopy.progress(progress)).monospacedDigit()
                        }
                        .progressViewStyle(.lz(.bar))
                    } else {
                        ProgressView { Text(LibraryCensusCopy.stageName(phase)) }
                            .progressViewStyle(.lz(.bar))
                    }
                    LZButton(LibraryCensusCopy.cancel, role: .secondary, size: .small) { runner.cancel() }
                        .accessibilityIdentifier("library-census-cancel")
                }
            }
            .accessibilityIdentifier("library-census-progress")
        } else {
            VStack(alignment: .leading, spacing: LZSpace.md) {
                switch phase {
                case .failed(let error):
                    Notice(.error, title: LibraryCensusCopy.failedTitle,
                           message: LibraryCensusCopy.failed(error, previous: runner.report != nil))
                case .cancelled:
                    Notice(.info, message: LibraryCensusCopy.cancelled(previous: runner.report != nil))
                default:
                    EmptyView()
                }
                // Once there are results, sharing them is the main action.
                LZButton(runner.report == nil ? LibraryCensusCopy.run : LibraryCensusCopy.runAgain, systemImage: "play.fill",
                         role: runner.report == nil ? .primary : .secondary, fullWidth: true) { runner.start() }
                    .accessibilityIdentifier("library-census-run")
                Text(LibraryCensusCopy.runNote(source: runner.sourceName)).lzText(.caption).foregroundStyle(.lz(.muted))
            }
        }
    }
}

/// The S2 marks, Share and every result section.
private struct CensusResults: View {
    let report: CensusReport
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: LZSpace.xl) {
            SectionHeader(LibraryCensusCopy.resultsTitle, caption: LibraryCensusCopy.resultsCaption(report))
            marks
            VStack(alignment: .leading, spacing: LZSpace.sm) {
                ShareLink(item: report.text, subject: Text(LibraryCensusCopy.shareSubject), preview: SharePreview(LibraryCensusCopy.shareSubject)) {
                    Label(LibraryCensusCopy.share, systemImage: "square.and.arrow.up")
                        .font(.lz(.callout).weight(.semibold))
                        .foregroundStyle(.lz(.accentInk))
                        .frame(maxWidth: .infinity, minHeight: 27)
                }
                .buttonStyle(.glassProminent)
                // LZButton's primary look, including its shape once the label may wrap.
                .buttonBorderShape(dynamicTypeSize.isAccessibilitySize ? .roundedRectangle(radius: LZRadius.lg) : .capsule)
                .tint(Color.lz(.accent))
                .controlSize(.large)
                .accessibilityIdentifier("library-census-share")
                Text(LibraryCensusCopy.shareNote).lzText(.caption).foregroundStyle(.lz(.muted))
            }
            ForEach(report.sections) { section in
                VStack(alignment: .leading, spacing: LZSpace.sm) {
                    Text(section.title).lzText(.label).foregroundStyle(.lz(.muted)).accessibilityAddTraits(.isHeader)
                    if !section.rows.isEmpty {
                        LZRowGroup {
                            ForEach(section.rows) { row in
                                // Long values read better under the label than squeezed beside it.
                                if row.value.count > 22 {
                                    ListRow(row.label, subtitle: row.value)
                                } else {
                                    ListRow(row.label, value: row.value)
                                }
                            }
                        }
                    }
                    ForEach(section.notes, id: \.self) { note in
                        Text(note).lzText(.caption).foregroundStyle(.lz(.muted))
                    }
                }
                .accessibilityIdentifier("library-census-section-\(section.id)")
            }
        }
        .accessibilityIdentifier("library-census-results")
    }

    private var marks: some View {
        PaperCard {
            VStack(alignment: .leading, spacing: LZSpace.lg) {
                Text(LibraryCensusCopy.marksTitle).lzText(.label).foregroundStyle(.lz(.muted))
                ForEach(report.marks) { mark in
                    VStack(alignment: .leading, spacing: LZSpace.xs) {
                        LZAdaptiveStack(spacing: LZSpace.sm, verticalAlignment: .firstTextBaseline) {
                            Text(mark.title)
                                .lzText(.headline)
                                .foregroundStyle(.lz(.ink))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Pill(mark.label, systemImage: mark.verdict.symbol, tone: mark.verdict.tone)
                                .fixedSize()
                        }
                        Text(mark.value).lzText(.subheadline).foregroundStyle(.lz(.ink))
                        Text(mark.rule).lzText(.caption).foregroundStyle(.lz(.muted))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("library-census-mark-\(mark.id)")
                }
            }
        }
    }
}

extension CensusVerdict {
    /// Pass reads as sage, fail as danger, a plan-changing flag as gold.
    var tone: LZTone {
        switch self {
        case .pass: .sage
        case .fail: .danger
        case .flag: .gold
        case .unavailable: .neutral
        }
    }

    var symbol: String {
        switch self {
        case .pass: "checkmark"
        case .fail: "xmark"
        case .flag: "flag.fill"
        case .unavailable: "minus"
        }
    }
}

/// Library census wording (a developer screen, English only). Numbers follow the iPhone's region;
/// the shared report uses a fixed format of its own.
nonisolated enum LibraryCensusCopy {
    static let screenTitle = "Library census"
    static let title = "Count what’s here."
    static let subtitle = "Phase 0 spike S2: the numbers that shape the indexer, measured on this iPhone."
    static let introTitle = "What it measures"
    static let introBody = "It reads your library’s metadata on this iPhone and samples a few hundred thumbnails."
    static let measures = [
        "How many photos have GPS",
        "How many are received (WhatsApp, Telegram and the like)",
        "How reliable the dates are",
        "How many have a local thumbnail of 224 px or more, with no download",
        "Duplicates and bursts",
        "How fast a metadata pass is",
    ]
    static let privacy = "Only aggregate numbers are shown: no photo, filename, place or date of a single photo. Nothing leaves your iPhone unless you share the report."

    static let needsAccessTitle = "The census needs photo access"
    static let photoAccessLink = "Photo access settings"
    static func needsAccess(_ access: PhotoAccess) -> String {
        switch access {
        case .notDetermined: "Lahza hasn’t asked for photo access yet. The census reads your library’s metadata, so it needs limited or full access."
        case .restricted: "Photo access is restricted on this iPhone, so the census can’t read the library."
        default: "Photo access is off. The census reads your library’s metadata, so it needs limited or full access."
        }
    }

    static let limitedTitle = "Limited access"
    static func limited(_ count: Int?) -> String {
        guard let count else { return "The census counts only the photos and videos you’ve shared." }
        return "The census counts only the \(count.formatted(.number)) photos and videos you’ve shared."
    }

    static let run = "Run census"
    static let runAgain = "Run again"
    static let cancel = "Cancel"
    static func runNote(source: String) -> String {
        source == CensusSourceName.photoKit
            ? "Reads this iPhone’s library. A large library can take several minutes: keep Lahza open (the screen stays on while it runs)."
            : "Reads the \(source.lowercased()): synthetic numbers for testing, no real photos."
    }

    static func step(_ stage: Int) -> String { "Step \(stage) of \(CensusRunner.stageCount)" }

    static func stageName(_ phase: CensusRunner.Phase) -> String {
        switch phase {
        case .metadata: "Reading metadata"
        case .filenames: "Reading filenames"
        case .thumbnails: "Checking local thumbnails"
        default: ""
        }
    }

    /// "1,250 of 12,480".
    static func progress(_ progress: CensusProgress) -> String {
        "\(progress.done.formatted(.number)) of \(progress.total.formatted(.number))"
    }

    static let failedTitle = "The census stopped"
    static func failed(_ error: CensusError, previous: Bool = false) -> String {
        let reason = switch error {
        case .noAccess: "Lahza can’t read your photos. Check Settings › Photo access, then run it again."
        case .mismatchedScan: "The library changed during the census. Run it again."
        case .unexpected(let message): "Something went wrong (\(message)). Run it again."
        }
        return previous ? "\(reason) \(previousResults)" : reason
    }
    static func cancelled(previous: Bool) -> String {
        previous ? "Census cancelled. Nothing from it was kept. \(previousResults)" : "Census cancelled. Nothing was kept."
    }
    private static let previousResults = "The results below are from the previous run."

    static let resultsTitle = "Results"
    static func resultsCaption(_ report: CensusReport) -> String {
        "\(report.source) · \(report.access == .limited ? "limited" : "full") access · \(report.library.total.formatted(.number)) photos and videos"
    }
    static let marksTitle = "S2 pass marks"
    static let share = "Share report"
    static let shareSubject = "Lahza library census"
    static let shareNote = "The report holds the numbers on this screen plus the run’s time and device details, as text and JSON. No photo, filename, place or photo date."
}
#endif
