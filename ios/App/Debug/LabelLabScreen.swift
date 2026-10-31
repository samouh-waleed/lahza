#if DEBUG
import ImageIO
import LZEmbedding
import LZIndex
import LZLibrary
import LZSearch
import Photos
import SwiftUI
import UIKit
import Vision

/// DEBUG: Settings › Developer › Label lab (content search step 2): how the Vision pass is doing on this iPhone (speed,
/// memory, photos only in iCloud, tags per photo), this iPhone's tag list against the one Lahza's word map was built
/// from, Vision at 256 against 360 pixels, iOS 27's captions, and the latest photos with their tags and flags. With the
/// image model on the iPhone (step 6, S3): vectors made, their speed, memory and heat, a step-by-step timing, the
/// vectors against the Mac's, and which Vision tags have no precision-recall curve. `Print report` writes the numbers
/// (no identifiers) to the console.
struct LabelLabScreen: View {
    @Environment(AppModel.self) private var model
    @State private var stats: VisualStats?
    @State private var samples: [VisualSample] = []
    @State private var sizes: LabelLabCopy.SizeComparison?
    @State private var captions: LabelLabCopy.CaptionCheck?
    @State private var benchmark: LabelLabCopy.Benchmark?
    @State private var parity: LabelLabCopy.Parity?
    @State private var curves: LabelLabCopy.Curves?
    @State private var modelMessage: String?
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
            imageModel(progress)
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
            Section("Tag curves") {
                if let curves {
                    LabeledContent("Tags without a curve", value: "\(curves.missing.count) of \(curves.total)")
                        .accessibilityIdentifier("label-lab-curves")
                    LabeledContent("Word map tags without one", value: curves.curatedMissing.isEmpty ? "none" : curves.curatedMissing.joined(separator: ", "))
                    if !curves.missing.isEmpty { Text(curves.missing.prefix(30).joined(separator: ", ")).lzText(.caption) }
                }
                Button("Check 3 recent photos") { Task { await checkCurves() } }
                    .disabled(working || samples.isEmpty)
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
                Button("Print report") {
                    print(LabelLabCopy.report(progress, stats: stats, sizes: sizes, captions: captions, benchmark: benchmark, parity: parity, curves: curves))
                }
            }
        }
        .navigationTitle("Label lab")
        .task(id: model.index.version) { await load() }
        .task { await runByItself() }
        // The pass runs only while Lahza is open: the screen stays on while the lab is shown.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .accessibilityIdentifier("label-lab")
    }

    /// Step 6's numbers (S3), when the image model is on the iPhone.
    @ViewBuilder private func imageModel(_ progress: VisualProgress?) -> some View {
        Section("Image model") {
            if let embedders = model.dependencies.embedders, let info = embedders.model {
                LabeledContent("Model", value: info.id)
                if let progress {
                    LabeledContent("Vectors", value: "\(progress.embedded ?? 0) of \(progress.total)")
                        .accessibilityIdentifier("label-lab-vectors")
                    LabeledContent("Vectors per second", value: progress.vectorsPerSecond.map { String(format: "%.1f", $0) } ?? "–")
                    LabeledContent("Model load", value: progress.modelLoad.map { String(format: "%.2f s", LabelLabCopy.seconds($0)) } ?? "–")
                    LabeledContent("Peak memory", value: progress.peakFootprint.map { "\($0 / 1_048_576) MB" } ?? "–")
                    LabeledContent("Hottest", value: LabelLabCopy.thermal(progress.peakThermal))
                }
                if let benchmark {
                    LabeledContent("Photos timed", value: "\(benchmark.photos)\(benchmark.passRunning ? " (pass running)" : "")")
                    LabeledContent("Image / Vision / model", value: String(format: "%.0f / %.0f / %.0f ms", benchmark.loadMs, benchmark.visionMs, benchmark.embedMs))
                    LabeledContent("One after another", value: String(format: "%.1f photos/s", benchmark.photosPerSecond))
                }
                Button("Time 30 photos, step by step") { Task { await runBenchmark(embedders) } }
                    .disabled(working || samples.isEmpty)
                if let parity {
                    ForEach(parity.reference, id: \.file) { item in
                        LabeledContent(item.file, value: String(format: "%.4f (CPU %.4f)", item.foreground, item.background))
                    }
                    if parity.photos > 0 {
                        LabeledContent("Neural Engine vs CPU", value: String(format: "min %.4f, mean %.4f on %d photos", parity.minimum, parity.mean, parity.photos))
                            .accessibilityIdentifier("label-lab-parity")
                    }
                }
                Button("Check vectors against the Mac") { Task { await checkParity(embedders) } }
                    .disabled(working)
                if let modelMessage { Text(modelMessage).lzText(.caption).foregroundStyle(.lz(.muted)) }
            } else {
                Text("No image model on this iPhone. On the Mac: make device-model DEVICE_ID=<udid>, then open Lahza again.").lzText(.caption)
            }
        }
    }

    /// `-LZLabAuto`: once the pass has been done for 10 seconds (the model's vectors made), the tag curves, the timing
    /// and the parity check, then the report on the console. At most 20 minutes of waiting.
    private func runByItself() async {
        guard model.dependencies.labelLabAuto else { return }
        let deadline = ContinuousClock.now + .seconds(1_200)
        var doneSince: ContinuousClock.Instant?
        while ContinuousClock.now < deadline {
            if model.index.status.visual?.state == .done {
                doneSince = doneSince ?? .now
                if ContinuousClock.now - doneSince! >= .seconds(10) { break }
            } else {
                doneSince = nil
            }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
        await load()
        await checkCurves()
        if let embedders = model.dependencies.embedders, embedders.model != nil {
            await runBenchmark(embedders)
            await checkParity(embedders)
        }
        let progress = model.index.status.visual
        print(LabelLabCopy.report(progress, stats: stats, sizes: sizes, captions: captions, benchmark: benchmark, parity: parity, curves: curves))
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

    /// Image, Vision and the model one after another on the latest photos (the pass overlaps them, so it runs faster).
    private func runBenchmark(_ embedders: any ImageEmbedderSource) async {
        working = true
        defer { working = false }
        do {
            let embedder = try await embedders.embedder(.foreground)
            var result = LabelLabCopy.Benchmark(passRunning: model.index.status.visual?.state == .running)
            let started = ContinuousClock.now
            for sample in samples.prefix(30) {
                let begun = ContinuousClock.now
                let image: CGImage
                switch await model.images.analysisImage(for: sample.localID, side: 360, minimumSide: 224) {
                case .image(let found), .reduced(let found): image = found
                case .inCloud, .missing: continue
                }
                let loaded = ContinuousClock.now
                _ = try? await VisionAnalyzer.analyze(image)
                let tagged = ContinuousClock.now
                _ = try await embedder.embed(image)
                let embedded = ContinuousClock.now
                result.photos += 1
                result.loadMs += LabelLabCopy.seconds(loaded - begun) * 1_000
                result.visionMs += LabelLabCopy.seconds(tagged - loaded) * 1_000
                result.embedMs += LabelLabCopy.seconds(embedded - tagged) * 1_000
            }
            guard result.photos > 0 else { return }
            result.photosPerSecond = Double(result.photos) / LabelLabCopy.seconds(ContinuousClock.now - started)
            result.loadMs /= Double(result.photos)
            result.visionMs /= Double(result.photos)
            result.embedMs /= Double(result.photos)
            benchmark = result
        } catch {
            modelMessage = "Timing failed: \(error)"
        }
    }

    /// The parity pictures `make model` saved, against PyTorch's vectors for them (≥0.99 is the bar), on the Neural
    /// Engine and on the CPU; then the two against each other on 10 of the latest photos, which never leave the iPhone.
    private func checkParity(_ embedders: any ImageEmbedderSource) async {
        working = true
        defer { working = false }
        guard let folder = (embedders as? ModelFolderEmbedderSource)?.folder else { return }
        do {
            let foreground = try await embedders.embedder(.foreground)
            let background = try await embedders.embedder(.background)
            var result = LabelLabCopy.Parity()
            if let data = try? Data(contentsOf: folder.appendingPathComponent("parity.json")),
               let reference = try? JSONDecoder().decode(LabelLabCopy.ParityFile.self, from: data) {
                for item in reference.images {
                    guard let source = CGImageSourceCreateWithURL(folder.appendingPathComponent(item.file) as CFURL, nil),
                          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
                    result.reference.append(.init(file: item.file, foreground: VectorMath.cosine(try await foreground.embed(image), item.embedding),
                                                  background: VectorMath.cosine(try await background.embed(image), item.embedding)))
                }
            }
            var cosines: [Float] = []
            for sample in samples.prefix(10) {
                guard case .image(let image) = await model.images.analysisImage(for: sample.localID, side: 360, minimumSide: 224) else { continue }
                cosines.append(VectorMath.cosine(try await foreground.embed(image), try await background.embed(image)))
            }
            result.photos = cosines.count
            result.minimum = cosines.min() ?? 0
            result.mean = cosines.isEmpty ? 0 : cosines.reduce(0, +) / Float(cosines.count)
            parity = result
            modelMessage = nil
        } catch {
            modelMessage = "Parity check failed: \(error)"
        }
        // The CPU copy isn't needed again; the pass loads what it uses.
        await embedders.release()
    }

    /// Which of Vision's tags come without a precision-recall curve: their likely and precise flags never pass, so the
    /// pass never stores them (E30).
    private func checkCurves() async {
        working = true
        defer { working = false }
        var result = LabelLabCopy.Curves()
        var missing = Set<String>()
        for sample in samples.prefix(3) {
            guard case .image(let image) = await model.images.analysisImage(for: sample.localID, side: 360, minimumSide: 224),
                  let observations = try? await ClassifyImageRequest().perform(on: image) else { continue }
            result.total = max(result.total, observations.count)
            missing.formUnion(observations.filter { !$0.hasPrecisionRecallCurve }.map(\.identifier))
        }
        result.missing = missing.sorted()
        result.curatedMissing = missing.intersection(VisualVocabulary.english.curatedLabels).sorted()
        curves = result
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
    struct Benchmark: Sendable {
        var passRunning = false
        var photos = 0
        var loadMs = 0.0
        var visionMs = 0.0
        var embedMs = 0.0
        var photosPerSecond = 0.0
    }

    struct Parity: Sendable {
        struct Item: Sendable {
            var file: String
            var foreground: Float
            var background: Float
        }

        /// The parity pictures against PyTorch.
        var reference: [Item] = []
        /// The Neural Engine against the CPU on the person's photos.
        var photos = 0
        var minimum: Float = 0
        var mean: Float = 0
    }

    /// `parity.json`'s pictures (the prompts are for the text side).
    struct ParityFile: Decodable {
        struct Image: Decodable {
            var file: String
            var embedding: [Float]
        }

        var images: [Image]
    }

    struct Curves: Sendable {
        var total = 0
        var missing: [String] = []
        var curatedMissing: [String] = []
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    static func thermal(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

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
    static func report(_ progress: VisualProgress?, stats: VisualStats?, sizes: SizeComparison?, captions: CaptionCheck?, benchmark: Benchmark? = nil,
                       parity: Parity? = nil, curves: Curves? = nil) -> String {
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
        if let progress, let embedded = progress.embedded {
            lines.append("model: vectors \(embedded) of \(progress.total), \(progress.vectorsPerSecond.map { String(format: "%.1f", $0) } ?? "-")/s, "
                         + "load \(progress.modelLoad.map { String(format: "%.2f s", seconds($0)) } ?? "-"), "
                         + "peak \(progress.peakFootprint.map { "\($0 / 1_048_576) MB" } ?? "-"), hottest \(thermal(progress.peakThermal))")
        }
        if let benchmark {
            lines.append("timed \(benchmark.photos) photos\(benchmark.passRunning ? " (pass running)" : ""): image \(String(format: "%.0f", benchmark.loadMs)) ms, "
                         + "Vision \(String(format: "%.0f", benchmark.visionMs)) ms, model \(String(format: "%.0f", benchmark.embedMs)) ms, "
                         + "\(String(format: "%.1f", benchmark.photosPerSecond)) photos/s one after another")
        }
        if let parity {
            let reference = parity.reference.map { String(format: "%@ %.4f (CPU %.4f)", $0.file, $0.foreground, $0.background) }.joined(separator: ", ")
            lines.append("parity vs PyTorch: \(reference.isEmpty ? "-" : reference); Neural Engine vs CPU on \(parity.photos) photos: "
                         + String(format: "min %.4f, mean %.4f", parity.minimum, parity.mean))
        }
        if let curves {
            lines.append("tag curves: \(curves.missing.count) of \(curves.total) without; word map tags without: "
                         + (curves.curatedMissing.isEmpty ? "none" : curves.curatedMissing.joined(separator: ", ")))
        }
        return lines.joined(separator: "\n")
    }
}
#endif
