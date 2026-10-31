#if DEBUG
import LZEmbedding
import LZIndex
import LZSearch
import SwiftUI
import UIKit

/// DEBUG: Settings › Developer › Description lab (content search step 7). A description against the photos' vectors:
/// from the bundled concept table when the words are a concept, otherwise from the text model on this iPhone, with
/// its load and encode times, the closest 20 photos and their z-scores against the library's reference sample. It also
/// checks the concept table against the text model here (cosine ≥0.99 is the bar). The photos stay on screen; the
/// console report (`Print report`, or `-LZLabAuto 1`) has numbers only.
struct DescriptionLabScreen: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var result: DescriptionLabCopy.Result?
    @State private var check: DescriptionLabCopy.TableCheck?
    @State private var probes: [DescriptionLabCopy.Probe] = []
    @State private var working = false
    @State private var message: String?

    var body: some View {
        Form {
            Section("Text side") {
                LabeledContent("Concept table", value: ConceptTable.bundled.map { "\($0.count) entries" } ?? "missing")
                if let encoder = model.dependencies.textEncoder, let info = encoder.model {
                    LabeledContent("Text model", value: info.id)
                } else {
                    Text("No text model on this iPhone: on the Mac, make tokenizer, then make device-model DEVICE_ID=<udid>.").lzText(.caption)
                }
                if let check {
                    LabeledContent("Model load (cold)", value: check.loadMs.map { String(format: "%.0f ms", $0) } ?? "–")
                    LabeledContent("Encode (warm)", value: String(format: "%.0f ms", check.encodeMs))
                    LabeledContent("Table vs this iPhone", value: String(format: "min %.4f, mean %.4f on %d", check.minimum, check.mean, check.entries))
                        .accessibilityIdentifier("description-lab-table")
                }
                Button("Check the concept table here") { Task { await checkTable() } }
                    .disabled(working || model.dependencies.textEncoder == nil)
            }
            Section("Describe") {
                TextField("A red car parked by the sea", text: $text)
                    .textInputAutocapitalization(.never)
                    .onSubmit { Task { await search(text) } }
                Button("Search") { Task { await search(text) } }
                    .disabled(working || text.trimmingCharacters(in: .whitespaces).isEmpty)
                if let result {
                    LabeledContent("From", value: result.source)
                    LabeledContent("Time", value: String(format: "%.0f ms", result.milliseconds))
                    LabeledContent("Photos with a vector", value: "\(result.photos)")
                    LabeledContent("z ≥ 3", value: "\(result.confident)")
                }
                if let message { Text(message).lzText(.caption).foregroundStyle(.lz(.muted)) }
            }
            if let result, !result.top.isEmpty {
                Section("Closest \(result.top.count)") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                        ForEach(result.top, id: \.localID) { item in
                            AssetThumbnail(localID: item.localID)
                                .aspectRatio(1, contentMode: .fill)
                                .overlay(alignment: .bottomTrailing) {
                                    Text(item.z.map { String(format: "%.1f", $0) } ?? "–")
                                        .font(.caption2.monospacedDigit()).padding(2).background(.black.opacity(0.6)).foregroundStyle(.white)
                                }
                        }
                    }
                }
            }
            if !probes.isEmpty {
                Section("Fixed descriptions") {
                    ForEach(probes, id: \.words) { probe in
                        LabeledContent(probe.words, value: DescriptionLabCopy.line(probe))
                    }
                }
            }
            Section {
                Button("Print report") { print(DescriptionLabCopy.report(check: check, probes: probes)) }
            }
        }
        .navigationTitle("Description lab")
        .task { await runByItself() }
        .accessibilityIdentifier("description-lab")
    }

    // MARK: Searching

    /// The open vector file (the Vision pass opens it; the lab does when it hasn't yet this launch).
    private func store() async -> VectorStore? {
        guard let vectors = model.index.vectors else { return nil }
        if let open = await vectors.current { return open }
        guard let info = model.dependencies.embedders?.model else { return nil }
        return try? await vectors.store(modelID: info.id, dimension: info.dimension)
    }

    private func search(_ words: String) async {
        working = true
        defer { working = false }
        do {
            guard let probe = try await probe(words, top: 20) else { return }
            result = probe.result
            message = nil
        } catch {
            message = "Search failed: \(error)"
        }
    }

    /// One description: its vector, every photo's score, the closest `top`.
    private func probe(_ words: String, top: Int) async throws -> DescriptionLabCopy.Probe? {
        guard let reader = model.index.reader, let store = await store() else {
            message = "No vectors yet: the image model makes them while Lahza is open."
            return nil
        }
        let started = ContinuousClock.now
        guard let found = try await DescriptionSearch.vector(for: words, table: ConceptTable.bundled, encoder: model.dependencies.textEncoder) else {
            message = "Not in the concept table, and no text model on this iPhone."
            return nil
        }
        let encoded = ContinuousClock.now
        let reference = ReferenceSample.pick(try await reader.snapshot().id)
        let scores = try await DescriptionSearch.scores(found.vector, store: store, reference: reference)
        let closest = scores.top(top)
        let ids = try await reader.localIdentifiers(for: closest.map(\.assetID))
        let source = if case .table(let name) = found.source { "concept table (\(name))" } else { "text model" }
        let result = DescriptionLabCopy.Result(
            source: source,
            milliseconds: DescriptionLabCopy.milliseconds(ContinuousClock.now - started), photos: scores.cosines.count,
            confident: scores.count(atLeast: 3), top: closest.compactMap { item in ids[item.assetID].map { .init(localID: $0, z: item.z) } })
        return DescriptionLabCopy.Probe(words: words, fromTable: found.source != .model, encodeMs: DescriptionLabCopy.milliseconds(encoded - started),
                                        result: result, topZ: closest.first?.z, tenthZ: closest.count >= 10 ? closest[9].z : nil)
    }

    /// The text model here against the table: 20 entries spread over it, each encoded over the table's templates.
    private func checkTable() async {
        guard let encoder = model.dependencies.textEncoder, let table = ConceptTable.bundled else { return }
        working = true
        defer { working = false }
        do {
            await encoder.release()
            var cosines: [Float] = []
            var encodeMs = 0.0
            for position in stride(from: 0, to: table.count, by: max(1, table.count / 20)).prefix(20) {
                let entry = table.index.entries[position]
                let started = ContinuousClock.now
                let vector = try await encoder.embed(table.index.templates.map { $0.replacingOccurrences(of: "{}", with: entry.phrase) })
                if !cosines.isEmpty { encodeMs += DescriptionLabCopy.milliseconds(ContinuousClock.now - started) }
                cosines.append(VectorMath.cosine(vector, table.vector(position)))
            }
            let load = await encoder.timings().load
            check = DescriptionLabCopy.TableCheck(entries: cosines.count, minimum: cosines.min() ?? 0, mean: cosines.reduce(0, +) / Float(max(1, cosines.count)),
                                                  loadMs: load.map(DescriptionLabCopy.milliseconds), encodeMs: encodeMs / Double(max(1, cosines.count - 1)))
        } catch {
            message = "Table check failed: \(error)"
        }
    }

    /// `-LZLabAuto`: the table check, then the fixed descriptions, then the report on the console.
    private func runByItself() async {
        guard model.dependencies.labelLabAuto else { return }
        // Wait for the index and its vectors (the pass opens the file).
        for _ in 0..<120 where await store() == nil {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
        await checkTable()
        var results: [DescriptionLabCopy.Probe] = []
        for words in DescriptionLabCopy.fixed {
            if let probe = try? await probe(words, top: 20) { results.append(probe) }
        }
        probes = results
        result = results.last?.result
        print(DescriptionLabCopy.report(check: check, probes: probes))
    }
}

nonisolated enum DescriptionLabCopy {
    /// Descriptions any library may hold: some in the concept table, some free text for the text model.
    static let fixed = ["sunset", "dog", "food", "people dancing", "mirror selfie", "a red car parked by the sea", "people dancing at a party",
                        "a birthday cake with candles", "kids playing in the snow", "a plate of food on a restaurant table"]

    struct Item: Sendable {
        var localID: String
        var z: Float?
    }

    struct Result: Sendable {
        var source: String
        var milliseconds: Double
        var photos: Int
        var confident: Int
        var top: [Item]
    }

    struct Probe: Sendable {
        var words: String
        var fromTable: Bool
        var encodeMs: Double
        var result: Result
        var topZ: Float?
        var tenthZ: Float?
    }

    struct TableCheck: Sendable {
        var entries: Int
        var minimum: Float
        var mean: Float
        var loadMs: Double?
        var encodeMs: Double
    }

    static func milliseconds(_ duration: Duration) -> Double {
        (Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18) * 1_000
    }

    /// "table · 3 ms · z≥3 41 · top z 7.2 · 10th 5.1".
    static func line(_ probe: Probe) -> String {
        func z(_ value: Float?) -> String { value.map { String(format: "%.1f", $0) } ?? "–" }
        return "\(probe.fromTable ? "table" : "model") · \(String(format: "%.0f", probe.encodeMs)) ms · z≥3 \(probe.result.confident) · "
            + "top z \(z(probe.topZ)) · 10th \(z(probe.tenthZ))"
    }

    /// Numbers and the fixed descriptions only: no photos, no identifiers.
    static func report(check: TableCheck?, probes: [Probe]) -> String {
        var lines = ["DESCRIPTION LAB"]
        if let check {
            lines.append("text model: load \(check.loadMs.map { String(format: "%.0f ms", $0) } ?? "-") cold, encode \(String(format: "%.0f ms", check.encodeMs)) "
                         + "warm (5 templates); table vs iPhone on \(check.entries): min \(String(format: "%.4f", check.minimum)), mean \(String(format: "%.4f", check.mean))")
        }
        if let first = probes.first { lines.append("photos with a vector: \(first.result.photos)") }
        for probe in probes { lines.append("\(probe.words): \(line(probe)), total \(String(format: "%.0f", probe.result.milliseconds)) ms") }
        return lines.joined(separator: "\n")
    }
}
#endif
