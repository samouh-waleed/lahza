#if DEBUG
import LZGeo
import LZIndex
import SwiftUI
import UIKit

/// DEBUG: Settings › Developer › Index inspector (spec §8.3). Aggregates only: never the change token's bytes,
/// coordinates or local identifiers.
struct IndexInspectorScreen: View {
    @Environment(AppModel.self) private var model
    @State private var data: IndexInspectorData?
    @State private var working = false

    var body: some View {
        let status = model.index.status
        Form {
            Section("Status") {
                LabeledContent("Phase", value: IndexInspectorCopy.phase(status.phase))
                    .accessibilityIdentifier("inspector-phase")
                LabeledContent("First build done", value: status.isPartial ? "no" : "yes")
                LabeledContent("Index version", value: "\(status.version)")
                LabeledContent("Place names", value: "\(IndexInspectorCopy.placeNames(status.placeNames.state)) · \(status.placeNames.named) of \(status.placeNames.eligible)")
                if let summary = status.summary {
                    LabeledContent("Assets", value: "\(summary.assets) (\(summary.photos) photos, \(summary.videos) videos)")
                        .accessibilityIdentifier("inspector-assets")
                    LabeledContent("Located", value: "\(summary.located)")
                    LabeledContent("Moments · trips · countries", value: "\(summary.moments) · \(summary.trips) · \(summary.countries)")
                    LabeledContent("Years", value: [summary.firstYear, summary.lastYear].compactMap { $0.map(String.init) }.joined(separator: "–"))
                }
            }
            if let data {
                Section("Sync") {
                    LabeledContent("Scan phase", value: data.scanPhase)
                    LabeledContent("Last full scan reason", value: data.scanReason ?? "–")
                    LabeledContent("Change token", value: data.hasChangeToken ? "present" : "none")
                    LabeledContent("Generation", value: "\(data.scanGeneration)")
                    LabeledContent("Read", value: "\(data.scanDone) of \(data.scanTotal)")
                    LabeledContent("Frontier", value: data.scanFrontier.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "–")
                    LabeledContent("Access scope", value: data.accessScope ?? "–")
                    LabeledContent("Last sync", value: data.lastSync.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "–")
                }
                Section("Versions") {
                    LabeledContent("Structure", value: data.structureVersion.map(String.init) ?? "–")
                    LabeledContent("Gazetteer", value: data.gazetteerVersion.map { String($0, radix: 16) } ?? "–")
                    LabeledContent("Device zone", value: data.deviceTimeZone ?? "–")
                }
                Section("Rows") {
                    ForEach(data.tables, id: \.name) { table in LabeledContent(table.name, value: "\(table.rows)") }
                }
                Section("Apple Maps naming") {
                    ForEach(data.placeNameStatus.sorted { $0.key < $1.key }, id: \.key) { status, cells in
                        LabeledContent(IndexInspectorCopy.cellStatus(status), value: "\(cells)")
                    }
                    LabeledContent("Backoff until", value: data.mapsBackoffUntil.map { $0.formatted(date: .omitted, time: .standard) } ?? "–")
                }
                Section("Home bases") {
                    ForEach(data.homeBases, id: \.year) { home in
                        LabeledContent("\(home.year)", value: "\(IndexInspectorCopy.homeSource(home.source)) · \(home.nights) nights · \(home.countryCode ?? "–") · \(home.timeZone ?? "–")")
                    }
                }
                Section("Trips") {
                    ForEach(data.trips, id: \.startDay) { trip in
                        LabeledContent("\(trip.label) · \(MomentCopy.dayRange(trip.startDay, trip.endDay))", value: "\(trip.items)\(trip.abroad ? " · abroad" : "")")
                    }
                }
                Section("Top places") {
                    ForEach(Array(data.topPlaces.enumerated()), id: \.offset) { _, place in
                        LabeledContent("\(place.name)", value: "\(IndexInspectorCopy.kind(place.kind)) · \(place.photos) · \(IndexInspectorCopy.source(place.source))")
                    }
                }
            }
            Section("Actions") {
                Button("Re-run structure") { act(.restructureAll) }
                Button("Forget change token") { act(.forgetChangeToken) }
                Button("Reset POI cache") { act(.resetPlaceNameCache) }
                Button("Full scan (rebuild)") { Task { working = true; await model.index.rebuild(); await model.index.settled(); working = false } }
                Button("Copy stats") { UIPasteboard.general.string = data.map { IndexInspectorCopy.stats($0, status: status) } }
            }
            .disabled(working || model.index.reader == nil)
        }
        .settingsForm("Index inspector")
        .accessibilityIdentifier("index-inspector")
        .task(id: status.version) { data = try? await model.index.reader?.inspector() }
    }

    private func act(_ maintenance: IndexStore.Maintenance) {
        Task {
            working = true
            await model.index.perform(maintenance)
            data = try? await model.index.reader?.inspector()
            working = false
        }
    }
}

/// The inspector's labels.
nonisolated enum IndexInspectorCopy {
    static func phase(_ phase: IndexStatus.Phase) -> String {
        switch phase {
        case .off(let reason): "off (\(reason))"
        case .preparing: "preparing"
        case .reading(let done, let total): "reading \(done)/\(total)"
        case .organizing: "organizing"
        case .ready: "Ready"
        case .paused: "paused"
        case .failed(let message): "failed: \(message)"
        }
    }

    static func placeNames(_ state: PlaceNameProgress.State) -> String {
        switch state {
        case .idle: "idle"
        case .running: "running"
        case .waitingForNetwork: "waiting for network"
        case .throttled: "throttled"
        case .off: "off"
        case .backgrounded: "backgrounded"
        case .done: "done"
        }
    }

    static func cellStatus(_ status: Int) -> String {
        ["0 pending", "1 named", "2 none", "3 retry", "4 gave up", "5 skipped (home)", "6 ineligible"].indices.contains(status)
            ? ["0 pending", "1 named", "2 none", "3 retry", "4 gave up", "5 skipped (home)", "6 ineligible"][status] : "\(status)"
    }

    static func homeSource(_ source: Int) -> String { ["estimated", "inherited", "user"].indices.contains(source) ? ["estimated", "inherited", "user"][source] : "?" }

    static func kind(_ kind: Int) -> String {
        PlaceKind(rawValue: kind).map { "\($0)" } ?? "\(kind)"
    }

    static func source(_ source: Int) -> String { [1: "gazetteer", 2: "Apple Maps", 3: "user", 4: "inferred"][source] ?? "?" }

    /// Aggregates only, for a bug report.
    static func stats(_ data: IndexInspectorData, status: IndexStatus) -> String {
        var lines = ["Lahza index · \(phase(status.phase)) · version \(status.version)",
                     "scan \(data.scanPhase) gen \(data.scanGeneration) read \(data.scanDone)/\(data.scanTotal) token \(data.hasChangeToken ? "yes" : "no") scope \(data.accessScope ?? "-")",
                     "structure \(data.structureVersion.map(String.init) ?? "-") zone \(data.deviceTimeZone ?? "-")"]
        lines += data.tables.map { "\($0.name) \($0.rows)" }
        lines.append("cells " + data.placeNameStatus.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: " "))
        lines.append("homes " + data.homeBases.map { "\($0.year):\(homeSource($0.source))" }.joined(separator: " "))
        lines.append("trips \(data.trips.count)")
        return lines.joined(separator: "\n")
    }
}
#endif
