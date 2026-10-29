import AVKit
import LZDesign
import LZGeo
import LZIndex
import LZLibrary
import LZSearch
import SwiftUI

/// One page of the viewer: a photo or video, when and where it was taken, and why a search matched it.
nonisolated struct ViewerItem: Identifiable, Hashable {
    /// The asset row id.
    var id: Int64
    var localID: String
    var isVideo: Bool
    /// Seconds (videos).
    var duration: Double
    var utc: Int64?
    /// Local wall seconds (``LocalTime``).
    var wall: Int64?
    var isFavorite: Bool
    /// The moment it is in (its place line and zone).
    var moment: MomentRow?
    /// Why the search matched it; empty outside a search's matches.
    var reasons: [Reason]

    init(hit: AssetHit, moment: MomentRow?) {
        id = hit.id
        localID = hit.localID
        isVideo = hit.kind == .video
        duration = hit.duration
        utc = hit.utc
        wall = hit.wall
        isFavorite = hit.isFavorite
        self.moment = moment
        reasons = hit.reasons
    }

    init(member: MomentDetailRows.Member, moment: MomentRow, reasons: [Reason] = []) {
        id = member.id
        localID = member.localID
        isVideo = member.isVideo
        duration = member.duration
        utc = member.utc
        wall = member.wall
        isFavorite = member.isFavorite
        self.moment = moment
        self.reasons = reasons
    }

    /// A search's grid, in its order (each tile with its card's moment).
    static func items(_ grid: ResultGrid, result: SearchResult) -> [ViewerItem] {
        let moments = Dictionary(result.cards.map { ($0.id, $0.moment) }, uniquingKeysWith: { first, _ in first })
        return grid.tiles.map { ViewerItem(hit: $0.hit, moment: moments[$0.card] ?? nil) }
    }
}

/// What the viewer pages through, and where it opens.
nonisolated struct ViewerSession: Identifiable {
    let id = UUID()
    var items: [ViewerItem]
    var start: Int
}

/// The viewer (search spec §7.1, asset viewer): the list it was opened from, a page per photo or video, swiped
/// sideways. On top, close, when it was taken (with the zone when it isn't this iPhone's) and where; at the bottom,
/// why it matched, with "Why this matched" for the sentences. Everything comes from what the iPhone holds: an original
/// only in iCloud shows its local version, and a video only in iCloud its poster.
struct AssetViewer: View {
    let session: ViewerSession
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var index: Int
    @State private var showsWhy = false

    init(session: ViewerSession) {
        self.session = session
        _index = State(initialValue: min(max(0, session.start), max(0, session.items.count - 1)))
    }

    var body: some View {
        let items = session.items
        let current = items.indices.contains(index) ? items[index] : nil
        TabView(selection: $index) {
            ForEach(Array(items.enumerated()), id: \.element.id) { position, item in
                ViewerPage(item: item, isCurrent: position == index)
                    .tag(position)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(.lz(.bg))
        .safeAreaInset(edge: .top, spacing: 0) {
            if let current { topBar(current, count: items.count) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let current, !current.reasons.isEmpty { bottomBar(current) }
        }
        .sheet(isPresented: $showsWhy) {
            if let current { WhyThisMatchedSheet(item: current) }
        }
        .accessibilityIdentifier("asset-viewer")
    }

    /// Close, the date and time with the zone, and the place.
    private func topBar(_ item: ViewerItem, count: Int) -> some View {
        let zone = model.dependencies.deviceTimeZone()
        return HStack(alignment: .top, spacing: LZSpace.md) {
            LZIconButton("xmark", label: ViewerCopy.close, style: .glass) { dismiss() }
                .accessibilityIdentifier("viewer-close")
            VStack(alignment: .leading, spacing: LZSpace.xxs) {
                Text(ViewerCopy.dateTime(item, deviceZone: zone))
                    .lzText(.headline)
                    .foregroundStyle(.lz(.ink))
                    .fixedSize(horizontal: false, vertical: true)
                if let place = ViewerCopy.placeLine(item, homeCountry: model.moments.homeCountryCode) {
                    Text(place)
                        .lzText(.subheadline)
                        .foregroundStyle(.lz(.muted))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(ViewerCopy.spokenTop(item, position: index, count: count, deviceZone: zone, homeCountry: model.moments.homeCountryCode))
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("viewer-when")
        }
        .padding(.horizontal, LZLayout.compactGutter)
        .padding(.vertical, LZSpace.sm)
        .background(.lz(.bg))
    }

    /// Why it matched, as pills, and "Why this matched". At accessibility text sizes the pills give way to the photo:
    /// the sheet says the same in sentences.
    private func bottomBar(_ item: ViewerItem) -> some View {
        VStack(alignment: .leading, spacing: LZSpace.sm) {
            if !dynamicTypeSize.isAccessibilitySize {
                LZFlowLayout(spacing: LZSpace.xs, lineSpacing: LZSpace.xs) {
                    ForEach(item.reasons, id: \.self) { reason in
                        Pill(reason.text, systemImage: reason.systemImage, tone: AskCopy.tone(reason))
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("viewer-reasons")
            }
            LZButton(ViewerCopy.whyThisMatched, systemImage: "text.magnifyingglass", role: .secondary, size: .small) { showsWhy = true }
                .accessibilityIdentifier("viewer-why")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, LZLayout.compactGutter)
        .padding(.top, LZSpace.sm)
        .padding(.bottom, LZSpace.xs)
        .background(.lz(.bg))
    }
}

// MARK: Pages

/// A photo at screen size, or a video.
private struct ViewerPage: View {
    let item: ViewerItem
    let isCurrent: Bool

    var body: some View {
        Group {
            if item.isVideo {
                ViewerVideo(item: item, isCurrent: isCurrent)
            } else {
                ViewerPhoto(item: item, placeholder: ViewerCopy.photoMissing)
            }
        }
        .padding(.vertical, LZSpace.xs)
    }
}

/// A screen-size image from what the iPhone holds; when the original is only in iCloud, the local version and "Full
/// quality is in iCloud". Also a video's poster.
private struct ViewerPhoto: View {
    let item: ViewerItem
    /// What shows when nothing can be read.
    let placeholder: String
    /// A note under the image (a video that can't play here).
    var note: String?
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    @State private var image: AssetImage?
    @State private var size: CGSize = .zero

    private struct Request: Hashable {
        var localID: String
        var pixels: Int
    }

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .overlay { content }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ViewerCopy.spokenImage(item, note: note ?? notice))
            .accessibilityAddTraits(.isImage)
            .accessibilityIdentifier(item.isVideo ? "viewer-poster" : "viewer-photo")
            .task(id: request) {
                guard let request else { return }
                let loaded = await model.images.displayImage(for: request.localID, maxPixel: request.pixels)
                if !Task.isCancelled { image = loaded }
            }
    }

    /// The long side of the page in pixels, once it is laid out.
    private var request: Request? {
        let points = max(size.width, size.height)
        guard points > 0 else { return nil }
        return Request(localID: item.localID, pixels: Int((points * displayScale).rounded(.up)))
    }

    /// The iCloud note for a reduced image.
    private var notice: String? {
        if case .reduced? = image { ViewerCopy.fullQualityInCloud } else { nil }
    }

    @ViewBuilder private var content: some View {
        switch image {
        case .image(let cgImage)?:
            picture(cgImage, note: note)
        case .reduced(let cgImage)?:
            picture(cgImage, note: note ?? ViewerCopy.fullQualityInCloud)
        case .inCloud?:
            ViewerPlaceholder(systemImage: "icloud", text: note ?? ViewerCopy.fullQualityInCloud)
        case .missing?:
            ViewerPlaceholder(systemImage: item.isVideo ? "video.slash" : "photo", text: note ?? placeholder)
        case nil:
            LZLoader(.star, size: 28, label: ViewerCopy.loading)
        }
    }

    private func picture(_ cgImage: CGImage, note: String?) -> some View {
        VStack(spacing: LZSpace.sm) {
            Image(decorative: cgImage, scale: displayScale)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let note {
                Label(note, systemImage: "icloud")
                    .lzText(.caption)
                    .foregroundStyle(.lz(.muted))
                    .padding(.bottom, LZSpace.xs)
                    .accessibilityIdentifier("viewer-icloud-note")
            }
        }
    }
}

/// A video from what the iPhone holds, played in place: it starts when its page is the one shown (a paused player shows
/// no frame) and pauses when the page goes. One only in iCloud, or that can't be read, shows its poster and says so.
private struct ViewerVideo: View {
    let item: ViewerItem
    let isCurrent: Bool
    @Environment(AppModel.self) private var model
    @State private var video: LoadedVideo?
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .accessibilityLabel(ViewerCopy.spokenImage(item, note: nil))
                    .accessibilityIdentifier("viewer-video")
            } else {
                switch video {
                case .inCloud?:
                    ViewerPhoto(item: item, placeholder: ViewerCopy.videoInCloud, note: ViewerCopy.videoInCloud)
                case .missing?:
                    ViewerPhoto(item: item, placeholder: ViewerCopy.videoMissing, note: ViewerCopy.videoMissing)
                case .item?, nil:
                    LZLoader(.star, size: 28, label: ViewerCopy.loading)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: item.localID) {
            let loaded = await model.videos.playerItem(for: item.localID)
            guard !Task.isCancelled else { return }
            if case .item(let playerItem) = loaded {
                let player = AVPlayer(playerItem: playerItem)
                if isCurrent { player.play() }
                self.player = player
            }
            video = loaded
        }
        .onChange(of: isCurrent) { _, current in
            if current { player?.play() } else { player?.pause() }
        }
        .onDisappear { player?.pause() }
    }
}

/// A glyph and a line, where an image would be.
private struct ViewerPlaceholder: View {
    let systemImage: String
    let text: String

    var body: some View {
        VStack(spacing: LZSpace.md) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(.lz(.muted))
                .accessibilityHidden(true)
            Text(text)
                .lzText(.subheadline)
                .foregroundStyle(.lz(.muted))
                .multilineTextAlignment(.center)
        }
        .padding(LZSpace.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.lz(.surface2), in: RoundedRectangle(cornerRadius: LZRadius.md, style: .continuous))
        .padding(.horizontal, LZLayout.compactGutter)
    }
}

// MARK: Why this matched

/// "Why this matched": a sentence for each reason ("No GPS in this photo. Location comes from a photo taken 3 min
/// earlier in the same outing.").
struct WhyThisMatchedSheet: View {
    let item: ViewerItem
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(ViewerCopy.whyThisMatched, subtitle: ViewerCopy.dateTime(item, deviceZone: model.dependencies.deviceTimeZone()))
                LZRowGroup {
                    ForEach(item.reasons, id: \.self) { reason in
                        ListRow(reason.detail, systemImage: reason.systemImage, tone: AskCopy.tone(reason))
                    }
                }
                .padding(.horizontal, LZLayout.gutter)
                .accessibilityIdentifier("why-this-matched")
                Text(AskCopy.capability)
                    .lzText(.caption)
                    .foregroundStyle(.lz(.muted))
                    .padding(.horizontal, LZLayout.gutter)
                    .padding(.top, LZSpace.md)
                    .padding(.bottom, LZSpace.xl)
            }
        }
        .lzSheetPresentation([.medium, .large])
    }
}

// MARK: Copy

nonisolated enum ViewerCopy {
    static let close = "Close"
    static let whyThisMatched = "Why this matched"
    static let loading = "Loading"
    static let fullQualityInCloud = "Full quality is in iCloud"
    static let videoInCloud = "This video is in iCloud"
    static let videoMissing = "This video can’t be played"
    static let photoMissing = "This photo can’t be shown"

    /// "Sat, Jun 14, 2025, 5:20 PM · Riyadh time" (the iPhone's region; the zone when it isn't this iPhone's), or
    /// "No date".
    static func dateTime(_ item: ViewerItem, deviceZone: TimeZone, locale: Locale = .autoupdatingCurrent) -> String {
        guard let wall = item.wall else { return AskCopy.noDate }
        let day = Int32((Double(wall) / 86_400).rounded(.down))
        let time = Date(timeIntervalSince1970: TimeInterval(wall))
            .formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: .gmt))
        let when = "\(LocalDateFormat.dayTitle(day, locale: locale)), \(time)"
        return zoneNote(item, deviceZone: deviceZone).map { "\(when) · \($0)" } ?? when
    }

    /// "Riyadh time" when the photo was taken on another offset than this iPhone's at that instant, else nil.
    static func zoneNote(_ item: ViewerItem, deviceZone: TimeZone) -> String? {
        guard let utc = item.utc, let wall = item.wall else { return nil }
        let instant = Date(timeIntervalSince1970: TimeInterval(utc))
        let offset = Int(wall - utc)
        guard offset != deviceZone.secondsFromGMT(for: instant) else { return nil }
        if let identifier = item.moment?.timeZone, let zone = TimeZone(identifier: identifier), zone.secondsFromGMT(for: instant) == offset {
            return MomentCopy.zoneName(zone, at: instant)
        }
        return TimeZone(secondsFromGMT: offset).map { MomentCopy.zoneName($0, at: instant) }
    }

    /// The moment's place line ("Al-Nakheel Park · Riyadh"), nil without a moment.
    static func placeLine(_ item: ViewerItem, homeCountry: String?) -> String? {
        item.moment.map { MomentCopy.placeLine($0, homeCountry: homeCountry) }
    }

    /// "Photo 3 of 26, Saturday, 14 June 2025, 5:20 PM, Riyadh time, Al-Nakheel Park · Riyadh".
    static func spokenTop(_ item: ViewerItem, position: Int, count: Int, deviceZone: TimeZone, homeCountry: String?) -> String {
        var parts = ["\(item.isVideo ? "Video" : "Photo") \(position + 1) of \(count)"]
        parts.append(dateTime(item, deviceZone: deviceZone).replacingOccurrences(of: " · ", with: ", "))
        if let place = placeLine(item, homeCountry: homeCountry) { parts.append(place) }
        return parts.joined(separator: ", ")
    }

    /// "Photo, favourite. Full quality is in iCloud".
    static func spokenImage(_ item: ViewerItem, note: String?) -> String {
        var parts = [item.isVideo ? "Video, \(MomentCopy.duration(item.duration))" : "Photo"]
        if item.isFavorite { parts.append("favourite") }
        if let note { parts.append(note) }
        return parts.joined(separator: ", ")
    }
}
