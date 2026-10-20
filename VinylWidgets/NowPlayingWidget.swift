import AppIntents
import SwiftUI
import UIKit
import WidgetKit

// MARK: - Model

/// What a widget shows: the album, its pressing, and where the song is.
struct WidgetRecord {
    var title: String
    var artist: String
    var album: String
    var albumKey: String
    var source: String
    var device: String?
    var isPlaying: Bool
    /// When the song started (or would have), so progress runs by itself.
    var startedAt: Date
    var duration: TimeInterval
    var pausedPosition: TimeInterval
    var artwork: UIImage?
    var palette: AlbumPalette
    var style: VinylStyle
    /// The app's "Spin the Record in Widgets" setting.
    var spins = false
    /// The record, drawn once per timeline and reused by every frame.
    var recordImage: UIImage?
    /// This frame's turn of the record, in degrees.
    var angle: Double = 0

    var endsAt: Date { startedAt.addingTimeInterval(duration) }

    var seed: UInt64 {
        var random = SeededRandom(string: albumKey)
        return random.next()
    }

    /// Each album rests at its own angle, like a still of a spinning record.
    var restingAngle: Double { Double(seed % 360) }

    static let placeholder = WidgetRecord(
        title: "Song Title", artist: "Artist", album: "Album", albumKey: "placeholder", source: "Spotify",
        device: nil, isPlaying: true, startedAt: Date().addingTimeInterval(-60), duration: 210,
        pausedPosition: 60, artwork: nil, palette: .neutral, style: .splatter
    )
}

struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let record: WidgetRecord?
}

// MARK: - Timeline

struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(date: Date(), record: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        // The widget gallery wants an answer fast: use what the app last saw.
        let record = NowPlayingSnapshot.load().map { WidgetSource.record(from: $0, at: Date()) }
        completion(NowPlayingEntry(date: Date(), record: record ?? (context.isPreview ? .placeholder : nil)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        Task {
            let now = Date()
            guard var record = await WidgetSource.current(at: now) else {
                completion(Timeline(entries: [NowPlayingEntry(date: now, record: nil)], policy: .after(now.addingTimeInterval(15 * 60))))
                return
            }
            record.recordImage = await MainActor.run { WidgetSource.renderRecord(record) }
            record.angle = record.restingAngle

            guard record.isPlaying, record.spins else {
                // Playing: look again just after this song ends. Otherwise every
                // 15 minutes. (The app also redraws widgets whenever it sees a change.)
                let next = record.isPlaying && record.duration > 0
                    ? max(now.addingTimeInterval(60), record.endsAt.addingTimeInterval(2))
                    : now.addingTimeInterval(15 * 60)
                completion(Timeline(entries: [NowPlayingEntry(date: now, record: record)], policy: .after(next)))
                return
            }

            // Widgets can't run an animation continuously, but each new frame
            // may animate for up to 2 seconds. Frames 2 s apart, each turning
            // the record on at 33⅓ rpm with a linear 2 s animation, read as a
            // steady spin. Two minutes of frames, then a fresh look at Spotify.
            let end = record.duration > 0 ? min(record.endsAt, now.addingTimeInterval(120)) : now.addingTimeInterval(120)
            var entries: [NowPlayingEntry] = []
            var t = now
            while t <= end {
                var frame = record
                // Measured from a fixed date so the turn never runs backwards between timelines.
                frame.angle = record.restingAngle + t.timeIntervalSinceReferenceDate * WidgetSource.degreesPerSecond
                entries.append(NowPlayingEntry(date: t, record: frame))
                t = t.addingTimeInterval(WidgetSource.frameInterval)
            }
            let next = record.duration > 0 && record.endsAt <= end ? record.endsAt.addingTimeInterval(2) : t
            completion(Timeline(entries: entries, policy: .after(next)))
        }
    }
}

/// Where the widgets learn what's playing: Spotify directly (so they stay
/// current with Vinyl closed), else the note the app left (Apple Music).
enum WidgetSource {
    static let degreesPerSecond: Double = 200 // 33⅓ rpm
    static let frameInterval: TimeInterval = 2 // the longest a widget may animate

    /// Draws the record once (it's the costly part); frames just rotate the image.
    @MainActor
    static func renderRecord(_ record: WidgetRecord) -> UIImage? {
        let renderer = ImageRenderer(content: RecordFace(
            diameter: 300,
            style: record.style,
            palette: record.palette,
            artwork: record.artwork,
            labelStyle: .picture,
            title: record.title,
            artist: record.artist,
            seed: record.seed
        ))
        renderer.scale = 2
        renderer.isOpaque = false
        return renderer.uiImage
    }

    static func current(at date: Date) async -> WidgetRecord? {
        let snapshot = NowPlayingSnapshot.load()
        let style = snapshot?.vinylStyle.flatMap(VinylStyle.init(rawValue:)) ?? .automatic
        var live = await spotifyRecord(at: date, style: style, reuse: snapshot)
        live?.spins = snapshot?.widgetSpin ?? false
        if let live, live.isPlaying { return live }
        if let snapshot, snapshot.isPlaying, snapshot.isCurrent(at: date) { return record(from: snapshot, at: date) }
        if let live { return live }
        guard var paused = snapshot else { return nil }
        // The app's note says it was playing, but that song has run out and we
        // can't know what came next: show it stopped where it ended.
        if paused.isPlaying && !paused.isCurrent(at: date) {
            paused.position = paused.duration
            paused.isPlaying = false
        }
        return record(from: paused, at: date)
    }

    static func record(from snapshot: NowPlayingSnapshot, at date: Date) -> WidgetRecord {
        let palette = snapshot.artwork.flatMap(AlbumPalette.extract(fromData:)) ?? .neutral
        let style = snapshot.vinylStyle.flatMap(VinylStyle.init(rawValue:)) ?? .automatic
        let position = snapshot.position(at: date)
        var record = WidgetRecord(
            title: snapshot.title, artist: snapshot.artist, album: snapshot.album, albumKey: snapshot.albumKey,
            source: snapshot.source, device: snapshot.device, isPlaying: snapshot.isPlaying,
            startedAt: date.addingTimeInterval(-position), duration: snapshot.duration, pausedPosition: position,
            artwork: snapshot.artwork.flatMap(UIImage.init(data:)), palette: palette,
            style: style.resolved(for: palette, albumKey: snapshot.albumKey)
        )
        record.spins = snapshot.widgetSpin ?? false
        return record
    }

    private static func spotifyRecord(at date: Date, style: VinylStyle, reuse snapshot: NowPlayingSnapshot?) async -> WidgetRecord? {
        guard let token = try? await SpotifyTokenStore.validAccessToken() else { return nil }
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player?additional_types=episode")!)
        request.timeoutInterval = 8
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let reply = try? JSONDecoder().decode(Reply.self, from: data),
              let item = reply.item
        else { return nil }

        let artists = (item.artists ?? []).map(\.name).joined(separator: ", ")
        let artist = artists.isEmpty ? (item.show?.publisher ?? item.show?.name ?? "") : artists
        let album = item.album?.name ?? item.show?.name ?? ""
        // Same key the app uses (Track.albumKey), so pressings match.
        let albumKey = "spotify|\(item.album?.artists?.first?.name ?? artist)|\(album.isEmpty ? item.name : album)".lowercased()

        var artworkData: Data?
        if let snapshot, snapshot.albumKey == albumKey, let cached = snapshot.artwork {
            artworkData = cached
        } else {
            let images = item.album?.images ?? item.show?.images ?? item.images ?? []
            // ~300 px: crisp in any widget, light on the widget's memory.
            if let cover = images.min(by: { abs(($0.width ?? 640) - 300) < abs(($1.width ?? 640) - 300) }),
               let url = URL(string: cover.url) {
                artworkData = try? await URLSession.shared.data(from: url).0
            }
        }
        let palette = artworkData.flatMap(AlbumPalette.extract(fromData:)) ?? .neutral
        let position = Double(reply.progress_ms ?? 0) / 1000
        return WidgetRecord(
            title: item.name, artist: artist, album: album, albumKey: albumKey, source: "Spotify",
            device: reply.device?.name, isPlaying: reply.is_playing,
            startedAt: date.addingTimeInterval(-position), duration: Double(item.duration_ms ?? 0) / 1000,
            pausedPosition: position, artwork: artworkData.flatMap(UIImage.init(data:)), palette: palette,
            style: style.resolved(for: palette, albumKey: albumKey)
        )
    }

    private struct Reply: Decodable {
        struct Device: Decodable { let name: String? }
        struct Image: Decodable { let url: String; let width: Int? }
        struct Artist: Decodable { let name: String }
        struct Album: Decodable { let name: String; let images: [Image]?; let artists: [Artist]? }
        struct Show: Decodable { let name: String; let publisher: String?; let images: [Image]? }
        struct Item: Decodable {
            let name: String
            let duration_ms: Int?
            let artists: [Artist]?
            let album: Album?
            let show: Show?
            let images: [Image]?
        }
        let is_playing: Bool
        let progress_ms: Int?
        let device: Device?
        let item: Item?
    }
}

// MARK: - Widget

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NowPlaying", provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetView(entry: entry)
        }
        .configurationDisplayName("Now Playing")
        .description("The record on your turntable, pressed in the album's colours, with play, pause and skip.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge, .systemExtraLarge,
            .accessoryCircular, .accessoryRectangular, .accessoryInline,
        ])
        .contentMarginsDisabled()
    }
}

struct NowPlayingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NowPlayingEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular: CircularAccessory(record: entry.record)
            case .accessoryRectangular: RectangularAccessory(record: entry.record)
            case .accessoryInline: InlineAccessory(record: entry.record)
            default:
                if let record = entry.record {
                    switch family {
                    case .systemSmall: SmallWidget(record: record)
                    case .systemMedium: MediumWidget(record: record)
                    default: LargeWidget(record: record, wide: family == .systemExtraLarge)
                    }
                } else {
                    EmptyWidget()
                }
            }
        }
        .containerBackground(for: .widget) {
            RoomBackground(palette: entry.record?.palette ?? .neutral)
        }
    }
}

// MARK: - Home Screen

/// The room behind the record, in the album's colour, lit from above.
struct RoomBackground: View {
    let palette: AlbumPalette

    var body: some View {
        ZStack {
            palette.background.color
            RadialGradient(colors: [.white.opacity(0.14), .clear], center: UnitPoint(x: 0.7, y: 0.2), startRadius: 0, endRadius: 320)
            LinearGradient(colors: [.clear, .black.opacity(0.22)], startPoint: .top, endPoint: .bottom)
        }
    }
}

/// The sleeve in front with its record slid out to the right, as in the app.
struct SleeveAndRecord: View {
    let record: WidgetRecord
    /// The sleeve's side; the whole thing is about 1.6× as wide.
    let size: CGFloat

    var body: some View {
        ZStack(alignment: .leading) {
            disc
                .frame(width: size * 0.96, height: size * 0.96)
                .rotationEffect(.degrees(record.angle))
                // Between spin frames, turn smoothly for the whole 2 s gap.
                .animation(record.spins && record.isPlaying ? .linear(duration: WidgetSource.frameInterval) : nil, value: record.angle)
                .shadow(color: .black.opacity(0.35), radius: size * 0.04, x: size * 0.01, y: size * 0.02)
            .offset(x: size * 0.6)
            Cover(image: record.artwork, size: size)
        }
        .frame(width: size * 1.58, height: size, alignment: .leading)
    }

    @ViewBuilder
    private var disc: some View {
        if let image = record.recordImage {
            Image(uiImage: image).resizable()
        } else {
            RecordFace(diameter: size * 0.96, style: record.style, palette: record.palette, artwork: record.artwork,
                       labelStyle: .picture, title: record.title, artist: record.artist, seed: record.seed)
        }
    }
}

struct Cover: View {
    let image: UIImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color(white: 0.18)
                    Image(systemName: "music.note").font(.system(size: size * 0.3)).foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: max(3, size * 0.02), style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: size * 0.05, y: size * 0.03)
    }
}

struct TrackText: View {
    let record: WidgetRecord
    var titleFont: Font = .headline
    var lines = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(record.title)
                .font(titleFont)
                .lineLimit(lines)
            Text(record.artist)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
    }
}

/// Runs by itself from the start time; static while paused.
struct WidgetProgress: View {
    let record: WidgetRecord

    var body: some View {
        if record.duration > 0 {
            if record.isPlaying {
                ProgressView(timerInterval: record.startedAt...record.endsAt, countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
            } else {
                ProgressView(value: min(record.pausedPosition, record.duration), total: record.duration)
            }
        }
    }
}

struct PlayPauseButton: View {
    let record: WidgetRecord
    let size: CGFloat

    var body: some View {
        Button(intent: TogglePlaybackIntent()) {
            Image(systemName: record.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.42, weight: .semibold))
                .frame(width: size, height: size)
                .background(.white.opacity(0.2), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityLabel(record.isPlaying ? "Pause" : "Play")
    }
}

struct WidgetControls: View {
    let record: WidgetRecord
    var size: CGFloat = 36

    var body: some View {
        HStack(spacing: size * 0.5) {
            Button(intent: PreviousTrackIntent()) {
                Image(systemName: "backward.fill").font(.system(size: size * 0.42)).frame(width: size, height: size)
            }
            .accessibilityLabel("Previous")
            PlayPauseButton(record: record, size: size * 1.15)
            Button(intent: NextTrackIntent()) {
                Image(systemName: "forward.fill").font(.system(size: size * 0.42)).frame(width: size, height: size)
            }
            .accessibilityLabel("Next")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }
}

struct SmallWidget: View {
    let record: WidgetRecord

    var body: some View {
        GeometryReader { geo in
            let side = geo.size.width
            VStack(alignment: .leading, spacing: 0) {
                SleeveAndRecord(record: record, size: side * 0.48)
                    .padding(.top, side * 0.09)
                Spacer(minLength: 4)
                HStack(alignment: .bottom, spacing: 6) {
                    TrackText(record: record, titleFont: .subheadline.weight(.semibold))
                        .font(.caption)
                    Spacer(minLength: 0)
                    PlayPauseButton(record: record, size: side * 0.2)
                }
            }
            .padding(.horizontal, side * 0.09)
            .padding(.bottom, side * 0.08)
        }
    }
}

struct MediumWidget: View {
    let record: WidgetRecord

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            HStack(spacing: h * 0.1) {
                SleeveAndRecord(record: record, size: h * 0.72)
                VStack(alignment: .leading, spacing: 4) {
                    SourceLine(record: record)
                    TrackText(record: record)
                    Spacer(minLength: 2)
                    WidgetProgress(record: record).tint(.white)
                    WidgetControls(record: record, size: h * 0.17)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(h * 0.12)
        }
    }
}

struct LargeWidget: View {
    let record: WidgetRecord
    let wide: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            if wide {
                // iPad extra large: the turntable on the left, the song on the right.
                HStack(spacing: w * 0.05) {
                    SleeveAndRecord(record: record, size: h * 0.74)
                    info(controlSize: h * 0.12, titleLines: 2)
                }
                .padding(h * 0.11)
            } else {
                // Budget: art 40%, controls ~10%, the rest text, progress and
                // breathing room, so nothing is ever pushed off the bottom.
                VStack(alignment: .leading, spacing: h * 0.035) {
                    SleeveAndRecord(record: record, size: min(h * 0.4, w * 0.55))
                        .frame(maxWidth: .infinity)
                    info(controlSize: h * 0.085, titleLines: 1)
                }
                .padding(.horizontal, w * 0.08)
                .padding(.top, h * 0.07)
                .padding(.bottom, h * 0.05)
            }
        }
    }

    private func info(controlSize: CGFloat, titleLines: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SourceLine(record: record)
            TrackText(record: record, titleFont: .title3.weight(.bold), lines: titleLines)
            Spacer(minLength: 0)
            WidgetProgress(record: record).tint(.white)
            WidgetControls(record: record, size: controlSize)
                .frame(maxWidth: .infinity)
        }
    }
}

struct SourceLine: View {
    let record: WidgetRecord

    var body: some View {
        Text([record.source, record.device].compactMap { $0 }.joined(separator: " · ").uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(.white.opacity(0.6))
            .lineLimit(1)
    }
}

struct EmptyWidget: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "record.circle")
                .font(.system(size: family == .systemSmall ? 36 : 44, weight: .light))
            Text("Put a record on")
                .font(.headline)
            if family != .systemSmall {
                Text("Play something in Spotify or Apple Music, or open Vinyl.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .opacity(0.7)
            }
        }
        .foregroundStyle(.white)
        .padding()
    }
}

// MARK: - Lock Screen

struct CircularAccessory: View {
    let record: WidgetRecord?

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            if let record, record.duration > 0 {
                if record.isPlaying {
                    ProgressView(timerInterval: record.startedAt...record.endsAt, countsDown: false) {
                        EmptyView()
                    } currentValueLabel: {
                        Image(systemName: "record.circle")
                    }
                    .progressViewStyle(.circular)
                } else {
                    Gauge(value: min(record.pausedPosition, record.duration), in: 0...record.duration) {
                        EmptyView()
                    } currentValueLabel: {
                        Image(systemName: "pause.fill")
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                }
            } else {
                Image(systemName: "record.circle").font(.title2)
            }
        }
        .widgetAccentable()
        .accessibilityLabel(record.map { "\($0.title) by \($0.artist)" } ?? "Nothing playing")
    }
}

struct RectangularAccessory: View {
    let record: WidgetRecord?

    var body: some View {
        if let record {
            VStack(alignment: .leading, spacing: 1) {
                Label(record.title, systemImage: record.isPlaying ? "record.circle" : "pause.circle")
                    .font(.headline)
                    .widgetAccentable()
                    .lineLimit(1)
                Text(record.artist)
                    .font(.caption)
                    .lineLimit(1)
                WidgetProgress(record: record)
            }
        } else {
            Label("Nothing playing", systemImage: "record.circle")
                .font(.headline)
        }
    }
}

struct InlineAccessory: View {
    let record: WidgetRecord?

    var body: some View {
        if let record {
            Label("\(record.title) · \(record.artist)", systemImage: "music.note")
        } else {
            Label("Vinyl", systemImage: "record.circle")
        }
    }
}
