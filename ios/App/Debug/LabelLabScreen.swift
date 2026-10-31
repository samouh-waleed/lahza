#if DEBUG
import LZIndex
import LZLibrary
import LZSearch
import Photos
import SwiftUI
import UIKit

/// DEBUG: Settings › Developer › Label lab (content search step 2): how the Vision pass is doing on this iPhone (speed,
/// memory, photos only in iCloud, tags per photo), this iPhone's tag list against the one Lahza's word map was built
/// from, Vision at 256 against 360 pixels, iOS 27's captions, and the latest photos with their tags and flags.
/// `Print report` writes the numbers (no identifiers) to the console.
struct LabelLabScreen: View {
    @Environment(AppModel.self) private var model
    @State private var stats: VisualStats?
    @State private var samples: [VisualSample] = []
    @State private var sizes: LabelLabCopy.SizeComparison?
    @State private var captions: LabelLabCopy.CaptionCheck?
    @State private var working = false

    var body: some View {
        let progress = model.index.status.visual
        Form {
            Section("Pass") {
                if let progress {
                    LabeledContent("State", value: LabelLabCopy.state(progress.state))
                    LabeledContent("Checked", value: "\(progress.checked) of \(progress.total)")
                        .accessibilityIdentifier("label-lab-checked")
                    LabeledContent("Only in iCloud", value: LabelLabCopy.share(progress.pendingCloud, of: progress.total))
                    LabeledContent("Photos per second", value: progress.photosPerSecond.map { String(format: "%.1f", $0) } ?? "–")
                    LabeledContent("Memory", value: progress.footprint.map { "\($0 / 1_048_576) MB" } ?? "–")
                } else {
                    Text("This index has no Vision pass.")
                }
            }
            if let stats {
                Section("Tags") {
                    LabeledContent("Tag rows per photo", value: stats.checked > 0 ? String(format: "%.1f", Double(stats.labelRows) / Double(stats.checked)) : "–")
                    LabeledContent("Tags given", value: "\(stats.labelsUsed) of \(stats.supported.count)")
                    LabeledContent("Failed", value: "\(stats.failed)")
                }
                Section("This iPhone's tag list") {
                    let check = LabelLabCopy.TagListCheck(device: stats.supported)
                    LabeledContent("Tags", value: "\(stats.supported.count) here, \(VisualVocabulary.english.labels.count) in Lahza's list")
                    LabeledContent("Word map tags missing here", value: check.missingCurated.isEmpty ? "none" : check.missingCurated.joined(separator: ", "))
                        .accessibilityIdentifier("label-lab-missing")
                    if !check.onlyHere.isEmpty { LabeledContent("Only here", value: check.onlyHere.prefix(12).joined(separator: ", ")) }
                    if !check.onlyInLahza.isEmpty { LabeledContent("Not here", value: check.onlyInLahza.prefix(12).joined(separator: ", ")) }
                }
            }
            Section("256 against 360 pixels") {
                if let sizes {
                    LabeledContent("Photos", value: "\(sizes.photos)")
                    LabeledContent("Vision at 256 / 360", value: String(format: "%.0f / %.0f ms", sizes.milliseconds256, sizes.milliseconds360))
                    LabeledContent("Same sure tags", value: String(format: "%.0f%%", sizes.agreement * 100))
                }
                Button("Compare on 10 recent photos") { Task { await compareSizes() } }
                    .disabled(working || samples.isEmpty)
            }
            Section("iOS 27 captions") {
                if let captions {
                    LabeledContent("With a caption", value: "\(captions.captioned) of \(captions.photos)")
                    LabeledContent("With keywords", value: "\(captions.withKeywords) of \(captions.photos)")
                    ForEach(captions.examples, id: \.self) { Text($0).lzText(.caption) }
                }
                Button("Read 20 recent photos") { Task { await checkCaptions() } }
                    .disabled(working || samples.isEmpty)
            }
            Section("Latest photos") {
                ForEach(samples) { sample in
                    HStack(alignment: .top, spacing: 12) {
                        AssetThumbnail(localID: sample.localID, side: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(LabelLabCopy.facts(sample)).lzText(.caption).foregroundStyle(.lz(.muted))
                            Text(LabelLabCopy.tags(sample.labels)).lzText(.subheadline).foregroundStyle(.lz(.ink))
                        }
                    }
                }
            }
            Section {
                Button("Print report") { print(LabelLabCopy.report(progress, stats: stats, sizes: sizes, captions: captions)) }
            }
        }
        .navigationTitle("Label lab")
        .task(id: model.index.version) { await load() }
        // The pass runs only while Lahza is open: the screen stays on while the lab is shown.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .accessibilityIdentifier("label-lab")
    }

    private func load() async {
        guard let reader = model.index.reader else { return }
        stats = try? await reader.visualStats()
        samples = (try? await reader.visualSamples(limit: 30)) ?? []
    }

    /// Vision over the 10 latest checked photos at both sizes: time per image, and how many of the likely or precise
    /// tags the two agree on.
    private func compareSizes() async {
        working = true
        defer { working = false }
        var comparison = LabelLabCopy.SizeComparison()
        var agreements: [Double] = []
        for sample in samples.prefix(10) {
            var sure: [Set<String>] = []
            for side in [256, 360] {
                guard case .image(let image) = await model.images.analysisImage(for: sample.localID, side: side, minimumSide: 1) else { continue }
                let started = ContinuousClock.now
                guard let analysis = try? await VisionAnalyzer.analyze(image) else { continue }
                let elapsed = ContinuousClock.now - started
                let milliseconds = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
                if side == 256 { comparison.milliseconds256 += milliseconds } else { comparison.milliseconds360 += milliseconds }
                sure.append(Set(analysis.labels.filter { !$0.flags.isEmpty }.map(\.name)))
            }
            guard sure.count == 2 else { continue }
            comparison.photos += 1
            let union = sure[0].union(sure[1])
            agreements.append(union.isEmpty ? 1 : Double(sure[0].intersection(sure[1]).count) / Double(union.count))
        }
        if comparison.photos > 0 {
            comparison.milliseconds256 /= Double(comparison.photos)
            comparison.milliseconds360 /= Double(comparison.photos)
            comparison.agreement = agreements.reduce(0, +) / Double(agreements.count)
        }
        sizes = comparison
    }

    /// iOS 27's `extendedMetadata`: whether Photos fills captions or keywords itself (content search, L4).
    private func checkCaptions() async {
        working = true
        defer { working = false }
        var check = LabelLabCopy.CaptionCheck()
        if #available(iOS 27, *) {
            let options = PHFetchOptions()
            options.prefetchAssetExtendedMetadata = true
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.fetchLimit = 20
            PHAsset.fetchAssets(with: .image, options: options).enumerateObjects { asset, _, _ in
                check.photos += 1
                let metadata = asset.extendedMetadata
                if let caption = metadata.caption, !caption.isEmpty {
                    check.captioned += 1
                    if check.examples.count < 3 { check.examples.append(caption) }
                }
                if !metadata.keywords.isEmpty { check.withKeywords += 1 }
            }
        }
        captions = check
    }
}

nonisolated enum LabelLabCopy {
    struct SizeComparison: Sendable {
        var photos = 0
        var milliseconds256 = 0.0
        var milliseconds360 = 0.0
        /// Mean overlap of the likely or precise tags (intersection over union).
        var agreement = 0.0
    }

    struct CaptionCheck: Sendable {
        var photos = 0
        var captioned = 0
        var withKeywords = 0
        /// Up to 3 captions (shown, never printed).
        var examples: [String] = []
    }

    /// This iPhone's Vision tag list against the bundled one the word map uses.
    struct TagListCheck {
        var missingCurated: [String]
        var onlyHere: [String]
        var onlyInLahza: [String]

        init(device: [String]) {
            let here = Set(device), lahza = Set(VisualVocabulary.english.labels)
            missingCurated = VisualVocabulary.english.curatedLabels.subtracting(here).sorted()
            onlyHere = here.subtracting(lahza).sorted()
            onlyInLahza = lahza.subtracting(here).sorted()
        }
    }

    static func state(_ state: VisualProgress.State) -> String {
        switch state {
        case .idle: "idle"
        case .running: "running"
        case .backgrounded: "paused (background)"
        case .done: "done"
        case .cooling: "waiting for the iPhone to cool"
        case .tooHot: "stopped: too hot"
        }
    }

    static func share(_ count: Int, of total: Int) -> String {
        total > 0 ? "\(count) (\(String(format: "%.1f", 100 * Double(count) / Double(total)))%)" : "\(count)"
    }

    /// "12 Jun 2026 · 2 faces · 3 people · utility".
    static func facts(_ sample: VisualSample) -> String {
        var parts = [sample.createdUTC.map { Date(timeIntervalSince1970: TimeInterval($0)).formatted(date: .abbreviated, time: .omitted) } ?? "No date"]
        if sample.faces > 0 { parts.append("\(sample.faces) face\(sample.faces == 1 ? "" : "s")") }
        if sample.humans > 0 { parts.append("\(sample.humans) \(sample.humans == 1 ? "person" : "people")") }
        if sample.isUtility { parts.append("utility") }
        return parts.joined(separator: " · ")
    }

    /// "soccer P 0.93 · grass L 0.61 · sport 0.12": P precise, L likely, nothing for the high-recall filter only.
    static func tags(_ labels: [VisualLabel]) -> String {
        guard !labels.isEmpty else { return "no tags" }
        return labels.prefix(10).map { label in
            let flag = label.flags.contains(.precise) ? " P" : label.flags.contains(.likely) ? " L" : ""
            return "\(label.name)\(flag) \(String(format: "%.2f", label.confidence))"
        }.joined(separator: " · ")
    }

    /// The numbers, for the console: no identifiers, no captions.
    static func report(_ progress: VisualProgress?, stats: VisualStats?, sizes: SizeComparison?, captions: CaptionCheck?) -> String {
        var lines = ["LABEL LAB"]
        if let progress {
            lines.append("checked \(progress.checked) of \(progress.total), only in iCloud \(share(progress.pendingCloud, of: progress.total)), "
                         + "\(progress.photosPerSecond.map { String(format: "%.1f", $0) } ?? "-") photos/s, "
                         + "footprint \(progress.footprint.map { "\($0 / 1_048_576) MB" } ?? "-"), state \(state(progress.state))")
        }
        if let stats {
            let check = TagListCheck(device: stats.supported)
            lines.append("tag rows \(stats.labelRows) (\(stats.checked > 0 ? String(format: "%.1f", Double(stats.labelRows) / Double(stats.checked)) : "-") per photo), "
                         + "tags given \(stats.labelsUsed), failed \(stats.failed)")
            lines.append("tag list: \(stats.supported.count) here; word map tags missing here: \(check.missingCurated.isEmpty ? "none" : check.missingCurated.joined(separator: ", ")); "
                         + "only here \(check.onlyHere.count), not here \(check.onlyInLahza.count)")
        }
        if let sizes {
            lines.append("256 vs 360: \(sizes.photos) photos, \(String(format: "%.0f / %.0f ms", sizes.milliseconds256, sizes.milliseconds360)), "
                         + "same sure tags \(String(format: "%.0f%%", sizes.agreement * 100))")
        }
        if let captions { lines.append("captions: \(captions.captioned) of \(captions.photos), keywords \(captions.withKeywords)") }
        return lines.joined(separator: "\n")
    }
}
#endif
