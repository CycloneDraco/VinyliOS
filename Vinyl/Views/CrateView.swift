import QuartzCore
import SwiftUI
import UIKit

/// One album on the shelf.
struct CrateItem: Identifiable, Equatable {
    enum Cover: Equatable {
        case file(URL)
        case remote(URL?)
    }

    var id: String
    var title: String
    var artist: String
    var cover: Cover
    /// `Track.albumURI`; nil for albums played before Vinyl recorded it.
    var uri: String?
}

/// The record crate: albums standing on a shelf you flick through, Cover
/// Flow style. Tap the one in front to open it and see its songs.
struct CrateView: View {
    @EnvironmentObject private var nowPlaying: NowPlayingService
    @EnvironmentObject private var spotify: SpotifyAuth
    @ObservedObject private var library = SpotifyLibrary.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Shelf: String, CaseIterable, Identifiable {
        case played = "Played in Vinyl"
        case library = "Spotify Library"
        var id: String { rawValue }
    }

    @State private var shelf: Shelf = .played
    @State private var search = ""
    @StateObject private var motion = ShelfMotion()
    @State private var openItem: CrateItem?
    @Namespace private var covers

    var body: some View {
        NavigationStack {
            ZStack {
                Backdrop(item: centeredItem)
                content
                if let openItem {
                    AlbumDetailView(item: openItem, namespace: covers, close: closeDetail, played: { dismiss() })
                        .zIndex(10)
                        .transition(.opacity)
                }
            }
            .navigationTitle("Crate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .searchable(text: $search, prompt: "Albums or artists")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                if spotify.isConnected {
                    ToolbarItem(placement: .principal) {
                        Picker("Shelf", selection: $shelf) {
                            ForEach(Shelf.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 360)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { noticeBanner }
        }
        .preferredColorScheme(.dark)
        .onChange(of: shelf) { _, _ in motion.jump(to: 0) }
        .onChange(of: search) { _, _ in motion.jump(to: 0) }
        .onChange(of: items.count) { _, count in motion.count = count }
        .onAppear { motion.count = items.count }
        .task(id: shelf) {
            if shelf == .library, spotify.canReadLibrary, library.albums.isEmpty { await library.loadMore() }
        }
        .task(id: search) {
            // Searching covers the whole library, not just the pages loaded so far.
            guard shelf == .library else { return }
            while !search.isEmpty && library.hasMore && library.error == nil && !Task.isCancelled {
                await library.loadMore()
            }
        }
    }

    // MARK: Items

    private var items: [CrateItem] {
        let all: [CrateItem]
        switch shelf {
        case .played:
            all = nowPlaying.recent.map {
                CrateItem(id: $0.key, title: $0.title, artist: $0.artist,
                          cover: .file(ArtworkStore.shared.url(forFile: $0.artworkFile)), uri: $0.albumURI)
            }
        case .library:
            all = library.albums.map {
                CrateItem(id: $0.uri, title: $0.title, artist: $0.artist, cover: .remote($0.artworkURL), uri: $0.uri)
            }
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.artist.localizedCaseInsensitiveContains(query) }
    }

    private var centeredIndex: Int {
        let list = items
        guard !list.isEmpty else { return 0 }
        return min(list.count - 1, max(0, Int(motion.position.rounded())))
    }

    private var centeredItem: CrateItem? {
        let list = items
        return list.isEmpty ? nil : list[centeredIndex]
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if shelf == .library && !spotify.canReadLibrary {
            EmptyShelf(symbol: "lock.open",
                       title: "Allow access to your library",
                       message: "Vinyl needs one more permission to show the albums saved in your Spotify library. Reconnect Spotify to grant it.") {
                Button {
                    Task {
                        await spotify.connect()
                        library.reset()
                        await library.loadMore()
                    }
                } label: {
                    Label("Reconnect Spotify", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.12, green: 0.73, blue: 0.33))
            }
        } else if items.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                ShelfCarousel(
                    items: items,
                    motion: motion,
                    openID: openItem?.id,
                    playingURI: nowPlaying.now.state == .playing ? nowPlaying.now.track?.albumURI : nil,
                    namespace: covers,
                    reduceMotion: reduceMotion,
                    open: openDetail
                )
                .frame(maxHeight: .infinity)
                .onChange(of: centeredIndex) { _, index in
                    if shelf == .library, index > items.count - 8 { Task { await library.loadMore() } }
                }

                if let item = centeredItem {
                    caption(for: item)
                        .padding(.bottom, 28)
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if shelf == .library {
            if library.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = library.error {
                EmptyShelf(symbol: "exclamationmark.triangle", title: "Couldn't load your library", message: error) {
                    Button("Try Again") { Task { await library.loadMore() } }
                }
            } else if !search.isEmpty {
                EmptyShelf(symbol: "magnifyingglass", title: "No matches", message: "None of your saved albums match “\(search)”.")
            } else {
                EmptyShelf(symbol: "heart", title: "No saved albums", message: "Albums you save in Spotify show up here.")
            }
        } else if !search.isEmpty {
            EmptyShelf(symbol: "magnifyingglass", title: "No matches", message: "Nothing you've played matches “\(search)”.")
        } else {
            EmptyShelf(symbol: "square.stack", title: "Nothing here yet", message: "Albums appear here as you play them, newest first.")
        }
    }

    private func caption(for item: CrateItem) -> some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text(item.title)
                    .font(.title2.weight(.bold))
                    .tracking(-0.3)
                Text(item.artist)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 30)
            .id(item.id)
            .transition(.opacity)

            HStack(spacing: 12) {
                Button {
                    Task {
                        guard let uri = item.uri else {
                            nowPlaying.notice = "Play this album once more and Vinyl will be able to start it from here."
                            return
                        }
                        if await nowPlaying.playAlbum(uri: uri) { dismiss() }
                    }
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(.headline)
                        .frame(minWidth: 110)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)

                Button { openDetail(item) } label: {
                    Label("Songs", systemImage: "list.bullet")
                        .font(.headline)
                        .frame(minWidth: 110)
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
            .controlSize(.large)
        }
        .animation(.easeOut(duration: 0.18), value: item.id)
    }

    @ViewBuilder
    private var noticeBanner: some View {
        if let notice = nowPlaying.notice {
            Text(notice)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 12)
                .padding(.horizontal, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: notice) {
                    try? await Task.sleep(nanoseconds: 4_500_000_000)
                    withAnimation { nowPlaying.notice = nil }
                }
        }
    }

    // MARK: Detail

    private func openDetail(_ item: CrateItem) {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.88)) {
            openItem = item
        }
    }

    private func closeDetail() {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.9)) {
            openItem = nil
        }
    }
}

// MARK: - Shelf

/// Drives the shelf: 1:1 drag, momentum projected from the release velocity,
/// and an under-damped spring to the nearest album that starts from wherever
/// the shelf is on screen, so it can be caught mid-flight.
@MainActor
final class ShelfMotion: NSObject, ObservableObject {
    /// Index of the album in front; fractional while moving.
    @Published private(set) var position: CGFloat = 0
    var count = 0

    private var velocity: CGFloat = 0 // albums per second
    private var target: CGFloat = 0
    private var link: CADisplayLink?
    private var dragOrigin: CGFloat?
    private var samples: [(time: CFTimeInterval, position: CGFloat)] = []

    // Momentum interactions earn a little bounce (damping 0.86, response 0.42 s).
    private let response: Double = 0.42
    private let damping: Double = 0.86

    func jump(to index: CGFloat) {
        stop()
        position = index
    }

    /// Touch-down: catch the shelf exactly where it is.
    func dragChanged(byAlbums delta: CGFloat) {
        if dragOrigin == nil {
            stop()
            dragOrigin = position
            samples = []
        }
        let raw = (dragOrigin ?? 0) - delta
        position = rubberBanded(raw)
        let now = CACurrentMediaTime()
        samples.append((now, position))
        samples.removeAll { now - $0.time > 0.1 }
    }

    func dragEnded() {
        dragOrigin = nil
        var v: CGFloat = 0
        if let first = samples.first, let last = samples.last, last.time > first.time {
            v = (last.position - first.position) / CGFloat(last.time - first.time)
        }
        // Apple's projection (deceleration 0.998): where a flick would come to rest.
        let projected = position + v * 0.998 / (1 - 0.998) / 1000
        settle(on: projected.rounded(), velocity: v)
    }

    /// Glide to an album (taps, accessibility).
    func go(to index: Int) {
        settle(on: CGFloat(index), velocity: velocity)
    }

    private func settle(on index: CGFloat, velocity v: CGFloat) {
        target = min(max(0, index), CGFloat(max(0, count - 1)))
        velocity = v
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stop() {
        link?.invalidate()
        link = nil
        velocity = 0
    }

    @objc private func step(_ link: CADisplayLink) {
        let dt = min(1.0 / 30, link.targetTimestamp - link.timestamp)
        let stiffness = pow(2 * .pi / response, 2)
        let friction = 4 * .pi * damping / response
        // A few sub-steps keep the spring stable at any frame rate.
        var x = Double(position), v = Double(velocity)
        let t = Double(target)
        for _ in 0..<4 {
            let h = dt / 4
            v += (-stiffness * (x - t) - friction * v) * h
            x += v * h
        }
        if abs(x - t) < 0.0005 && abs(v) < 0.005 {
            position = target
            stop()
        } else {
            position = CGFloat(x)
            velocity = CGFloat(v)
        }
    }

    /// Past either end the shelf resists progressively instead of stopping dead.
    private func rubberBanded(_ value: CGFloat) -> CGFloat {
        let upper = CGFloat(max(0, count - 1))
        func band(_ over: CGFloat) -> CGFloat { over * 1.2 * 0.55 / (1.2 + 0.55 * over) }
        if value < 0 { return -band(-value) }
        if value > upper { return upper + band(value - upper) }
        return value
    }
}

struct ShelfCarousel: View {
    let items: [CrateItem]
    @ObservedObject var motion: ShelfMotion
    let openID: String?
    let playingURI: String?
    let namespace: Namespace.ID
    let reduceMotion: Bool
    let open: (CrateItem) -> Void

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.height * 0.66, geo.size.width * 0.42, 460)
            let position = motion.position
            let low = max(0, Int(position) - 7)
            let high = min(items.count - 1, Int(position) + 8)
            ZStack {
                if low <= high {
                    ForEach(low...high, id: \.self) { index in
                        let item = items[index]
                        let offset = CGFloat(index) - position
                        ShelfCover(item: item, size: size, playing: item.uri != nil && item.uri == playingURI)
                            .matchedGeometryEffect(id: item.id, in: namespace, isSource: openID != item.id)
                            .opacity(openID == item.id ? 0 : 1)
                            .modifier(ShelfPlacement(offset: offset, size: size, flat: reduceMotion))
                            .zIndex(-Double(abs(offset)))
                            .onTapGesture {
                                if abs(offset) < 0.5 { open(item) } else { motion.go(to: index) }
                            }
                            .accessibilityHidden(abs(offset) >= 0.5)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in motion.dragChanged(byAlbums: value.translation.width / (size * 0.55)) }
                    .onEnded { _ in motion.dragEnded() }
            )
            .sensoryFeedback(.selection, trigger: Int(position.rounded()))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(currentLabel)
            .accessibilityAdjustableAction { direction in
                let index = Int(position.rounded()) + (direction == .increment ? 1 : -1)
                motion.go(to: min(max(0, index), items.count - 1))
            }
        }
    }

    private var currentLabel: String {
        let index = min(items.count - 1, max(0, Int(motion.position.rounded())))
        guard items.indices.contains(index) else { return "Shelf" }
        return "\(items[index].title) by \(items[index].artist), \(index + 1) of \(items.count)"
    }
}

/// Where an album stands on the shelf: facing you in front, turned on edge
/// and stacked toward the sides, like browsing a record store bin.
struct ShelfPlacement: ViewModifier {
    let offset: CGFloat
    let size: CGFloat
    let flat: Bool

    func body(content: Content) -> some View {
        let clamped = min(max(offset, -1), 1)
        let side = abs(offset) <= 1 ? offset * size * 0.62 : (offset > 0 ? 1 : -1) * (size * 0.62 + (abs(offset) - 1) * size * 0.2)
        let scale = 1 - 0.14 * min(abs(offset), 1)
        let fade = max(0, min(1, 6.5 - abs(offset)))
        if flat {
            // Reduce Motion: no 3D turn, just a calm row.
            content
                .scaleEffect(scale)
                .offset(x: offset * size * 0.8)
                .opacity(fade)
        } else {
            content
                .rotation3DEffect(.degrees(-clamped * 64), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                .scaleEffect(scale)
                .offset(x: side)
                .opacity(fade)
        }
    }
}

/// A sleeve on the shelf, with a soft reflection on the shelf's gloss.
struct ShelfCover: View {
    let item: CrateItem
    let size: CGFloat
    let playing: Bool

    var body: some View {
        VStack(spacing: 3) {
            sleeve
                .shadow(color: .black.opacity(0.45), radius: size * 0.04, y: size * 0.025)
            sleeve
                .scaleEffect(x: 1, y: -1)
                .frame(height: size * 0.32, alignment: .bottom)
                .clipped()
                .mask(LinearGradient(colors: [.black.opacity(0.28), .clear], startPoint: .top, endPoint: .bottom))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .frame(width: size, height: size * 1.32 + 3, alignment: .top)
        .offset(y: size * 0.16)
    }

    private var sleeve: some View {
        CoverImage(cover: item.cover)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.012, style: .continuous))
            .overlay(
                // Light catching the top edge of the card.
                RoundedRectangle(cornerRadius: size * 0.012, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center), lineWidth: 1)
            )
            .overlay(alignment: .bottomTrailing) {
                if playing {
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative)
                        .font(.system(size: max(14, size * 0.05), weight: .bold))
                        .padding(size * 0.03)
                        .background(.ultraThinMaterial, in: Circle())
                        .padding(size * 0.03)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("\(item.title) by \(item.artist)")
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens the album")
    }
}

/// The room behind the shelf takes the colours of the album in front.
struct Backdrop: View {
    let item: CrateItem?

    var body: some View {
        ZStack {
            Color.black
            if let item {
                CoverImage(cover: item.cover)
                    .scaledToFill()
                    .blur(radius: 80, opaque: true)
                    .saturation(1.3)
                    .opacity(0.75)
                    .id(item.id)
                    .transition(.opacity)
            }
            LinearGradient(colors: [.black.opacity(0.25), .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
        }
        .animation(.easeInOut(duration: 0.5), value: item?.id)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - Album detail

/// The album opened out of the shelf: cover, details and its songs.
/// Tap a song to play from there. Drag the cover down (or tap outside) to
/// put it back; it returns to its place on the shelf.
struct AlbumDetailView: View {
    @EnvironmentObject private var nowPlaying: NowPlayingService
    let item: CrateItem
    let namespace: Namespace.ID
    let close: () -> Void
    /// Playback started; the crate can step aside.
    let played: () -> Void

    @State private var detail: AlbumDetail?
    @State private var loadError: String?
    @State private var drag: CGFloat = 0
    @State private var starting: String?

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > 640
            let coverSize = wide ? min(geo.size.height * 0.62, geo.size.width * 0.36) : min(geo.size.width * 0.62, 300)
            ZStack {
                // Dim to focus; tapping the dimmed area puts the album back.
                Color.black.opacity(0.5 * Double(1 - min(1, drag / 400)))
                    .ignoresSafeArea()
                    .onTapGesture(perform: close)

                Group {
                    if wide {
                        HStack(alignment: .top, spacing: 36) {
                            header(coverSize: coverSize)
                                .frame(width: coverSize)
                            songs
                        }
                    } else {
                        VStack(spacing: 18) {
                            header(coverSize: coverSize)
                            songs
                        }
                    }
                }
                .padding(wide ? 34 : 20)
                .frame(maxWidth: 1000, maxHeight: wide ? min(geo.size.height - 40, 760) : .infinity)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .frame(width: 34, height: 34)
                            .background(.thinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(14)
                    .accessibilityLabel("Close")
                }
                .padding(wide ? 30 : 12)
                .offset(y: drag)
            }
        }
        .task(id: item.id) { await load() }
    }

    private func header(coverSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            CoverImage(cover: item.cover)
                .frame(width: coverSize, height: coverSize)
                .clipShape(RoundedRectangle(cornerRadius: coverSize * 0.012, style: .continuous))
                .matchedGeometryEffect(id: item.id, in: namespace)
                .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
                .gesture(dismissDrag)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(detail?.title ?? item.title)
                    .font(.title.weight(.bold))
                    .tracking(-0.4)
                    .lineLimit(2)
                Text(detail?.artist ?? item.artist)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let summary {
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
            }
            Button {
                play(from: nil)
            } label: {
                Label(starting == "" ? "Starting…" : "Play Album", systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.white)
            .foregroundStyle(.black)
            .disabled(item.uri == nil || starting != nil)
        }
    }

    @ViewBuilder
    private var songs: some View {
        if let detail {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    let multiDisc = Set(detail.tracks.map(\.disc)).count > 1
                    ForEach(Array(detail.tracks.enumerated()), id: \.element.id) { index, track in
                        if multiDisc && (index == 0 || detail.tracks[index - 1].disc != track.disc) {
                            Text("Disc \(track.disc)")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, index == 0 ? 0 : 14)
                                .padding(.bottom, 4)
                                .padding(.horizontal, 12)
                        }
                        Button { play(from: track.id) } label: {
                            TrackRow(track: track,
                                     current: nowPlaying.now.track?.id == track.id,
                                     playing: nowPlaying.now.state == .playing,
                                     starting: starting == track.id)
                        }
                        .buttonStyle(RowPressStyle())
                        .disabled(starting != nil)
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
        } else if let loadError {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(.secondary)
                Text(loadError).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try Again") { Task { await load() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var summary: String? {
        guard let detail else { return nil }
        let minutes = Int(detail.tracks.reduce(0) { $0 + $1.duration } / 60)
        let songs = "\(detail.tracks.count) song\(detail.tracks.count == 1 ? "" : "s")"
        return [detail.year, songs, "\(minutes) min"].compactMap { $0 }.joined(separator: " · ")
    }

    /// Follows the finger down 1:1 (resisting upward); decides on release
    /// from where the gesture was heading, not just where it stopped.
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                let y = value.translation.height
                drag = y >= 0 ? y : -(-y * 0.55 * 60 / (60 + 0.55 * -y))
            }
            .onEnded { value in
                if value.predictedEndTranslation.height > 220 {
                    close()
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { drag = 0 }
                }
            }
    }

    private func load() async {
        loadError = nil
        guard let uri = item.uri else {
            loadError = "Play this album once more and Vinyl will be able to list its songs."
            return
        }
        do {
            detail = try await nowPlaying.albumDetail(uri: uri)
            if detail == nil { loadError = "This album isn't in your Apple Music library any more." }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func play(from trackID: String?) {
        guard let uri = item.uri, starting == nil else { return }
        starting = trackID ?? ""
        Task {
            let ok = await nowPlaying.playAlbum(uri: uri, startingAt: trackID)
            starting = nil
            if ok { played() }
        }
    }
}

struct TrackRow: View {
    let track: AlbumTrack
    let current: Bool
    let playing: Bool
    let starting: Bool

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                if starting {
                    ProgressView().controlSize(.small)
                } else if current {
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative, isActive: playing)
                        .foregroundStyle(.primary)
                } else {
                    Text("\(track.number)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .fontWeight(current ? .semibold : .regular)
                    .lineLimit(1)
                if let artist = track.artist {
                    Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            Text(Scrubber.format(track.duration))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Plays the album from this song")
    }
}

/// Highlights on touch-down, not on release.
struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(configuration.isPressed ? 0.14 : 0))
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Covers

/// Loads covers once and keeps them in memory while you browse: from the
/// artwork cache on disk, or from Spotify.
@MainActor
final class CoverCache {
    static let shared = CoverCache()
    private let cache = NSCache<NSURL, UIImage>()

    init() { cache.countLimit = 200 }

    func cached(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    func load(_ url: URL) async -> UIImage? {
        if let hit = cached(url) { return hit }
        let image: UIImage? = await Task.detached(priority: .userInitiated) {
            let data: Data?
            if url.isFileURL {
                data = try? Data(contentsOf: url)
            } else {
                data = try? await URLSession.shared.data(from: url).0
            }
            return data.flatMap { UIImage(data: $0)?.preparingThumbnail(of: CGSize(width: 600, height: 600)) }
        }.value
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }
}

struct CoverImage: View {
    let cover: CrateItem.Cover
    @State private var image: UIImage?

    private var url: URL? {
        switch cover {
        case .file(let url): return url
        case .remote(let url): return url
        }
    }

    var body: some View {
        ZStack {
            if let image = image ?? url.flatMap({ CoverCache.shared.cached($0) }) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color(white: 0.16)
                    Image(systemName: "record.circle")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: url) {
            guard let url else { return }
            image = await CoverCache.shared.load(url)
        }
    }
}

struct EmptyShelf<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var actions: () -> Actions

    init(symbol: String, title: String, message: String, @ViewBuilder actions: @escaping () -> Actions) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actions = actions
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            actions()
                .padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyShelf where Actions == EmptyView {
    init(symbol: String, title: String, message: String) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

// MARK: - Spotify library

/// Saved albums, fetched a page at a time and kept for the session.
@MainActor
final class SpotifyLibrary: ObservableObject {
    static let shared = SpotifyLibrary()

    @Published private(set) var albums: [SpotifyAlbum] = []
    @Published private(set) var total: Int?
    @Published private(set) var isLoading = false
    @Published var error: String?

    private var nextOffset = 0
    private let pageSize = 50

    var hasMore: Bool { total.map { nextOffset < $0 } ?? true }

    func reset() {
        albums = []
        total = nil
        nextOffset = 0
        error = nil
    }

    func loadMore() async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let page = try await SpotifyAPI.shared.savedAlbums(offset: nextOffset, limit: pageSize)
            let known = Set(albums.map(\.id))
            albums += page.albums.filter { !known.contains($0.id) }
            total = page.total
            nextOffset += pageSize
        } catch SpotifyAPIError.forbidden(let message) where message.localizedCaseInsensitiveContains("scope") {
            // The login predates library access.
            error = "Spotify didn't allow Vinyl to read your library. Reconnect Spotify in Settings and try again."
        } catch {
            self.error = error.localizedDescription
        }
    }
}
