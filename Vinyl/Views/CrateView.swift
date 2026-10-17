import SwiftUI
import UIKit

/// The record crate: albums played in Vinyl and the Spotify library, as a
/// grid of covers. Tap one to play it from the first track.
struct CrateView: View {
    @EnvironmentObject private var nowPlaying: NowPlayingService
    @EnvironmentObject private var spotify: SpotifyAuth
    @ObservedObject private var library = SpotifyLibrary.shared
    @Environment(\.dismiss) private var dismiss

    enum Shelf: String, CaseIterable, Identifiable {
        case played = "Played in Vinyl"
        case library = "Spotify Library"
        var id: String { rawValue }
    }

    @State private var shelf: Shelf = .played
    @State private var search = ""
    @State private var starting: String?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 230), spacing: 20, alignment: .top)]

    var body: some View {
        NavigationStack {
            Group {
                switch shelf {
                case .played: playedShelf
                case .library: libraryShelf
                }
            }
            .navigationTitle("Crate")
            .navigationBarTitleDisplayMode(.inline)
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
            .safeAreaInset(edge: .bottom) {
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
            .animation(.easeInOut(duration: 0.25), value: nowPlaying.notice)
        }
    }

    // MARK: Played in Vinyl

    @ViewBuilder
    private var playedShelf: some View {
        let albums = nowPlaying.recent.filter { matches($0.title, $0.artist) }
        if nowPlaying.recent.isEmpty {
            EmptyShelf(symbol: "square.stack",
                       title: "Nothing here yet",
                       message: "Albums appear here as you play them, newest first.")
        } else if albums.isEmpty {
            EmptyShelf(symbol: "magnifyingglass", title: "No matches", message: "Nothing you've played matches \"\(search)\".")
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 26) {
                    ForEach(albums) { album in
                        AlbumCell(
                            title: album.title,
                            artist: album.artist,
                            cover: .file(ArtworkStore.shared.url(forFile: album.artworkFile)),
                            isPlaying: isPlaying(album.albumURI),
                            isStarting: album.albumURI != nil && starting == album.albumURI
                        ) {
                            play(album.albumURI)
                        }
                    }
                }
                .padding(20)
                footer("Playing an album here starts it from track 1. With Spotify, that needs Premium and Spotify open on a device.")
            }
        }
    }

    // MARK: Spotify Library

    @ViewBuilder
    private var libraryShelf: some View {
        if !spotify.canReadLibrary {
            EmptyShelf(symbol: "lock.open",
                       title: "Allow access to your library",
                       message: "Vinyl needs one more permission to show the albums saved in your Spotify library. Reconnect Spotify to grant it.") {
                Button {
                    Task {
                        await spotify.connect()
                        library.reset()
                    }
                } label: {
                    Label("Reconnect Spotify", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.12, green: 0.73, blue: 0.33))
            }
        } else {
            let albums = library.albums.filter { matches($0.title, $0.artist) }
            ScrollView {
                LazyVGrid(columns: columns, spacing: 26) {
                    ForEach(albums) { album in
                        AlbumCell(
                            title: album.title,
                            artist: album.artist,
                            cover: .remote(album.artworkURL),
                            isPlaying: isPlaying(album.uri),
                            isStarting: starting == album.uri
                        ) {
                            play(album.uri)
                        }
                        .onAppear {
                            // Fetch the next page as the end comes into view.
                            if album.id == library.albums.last?.id { Task { await library.loadMore() } }
                        }
                    }
                }
                .padding(20)

                if library.isLoading {
                    ProgressView().padding(30)
                } else if let error = library.error {
                    VStack(spacing: 10) {
                        Text(error).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Try Again") { Task { await library.loadMore() } }
                    }
                    .padding(30)
                } else if library.albums.isEmpty {
                    EmptyShelf(symbol: "heart", title: "No saved albums",
                               message: "Albums you save in Spotify show up here.")
                } else if !search.isEmpty && albums.isEmpty {
                    EmptyShelf(symbol: "magnifyingglass", title: "No matches",
                               message: "None of your saved albums match \"\(search)\".")
                } else if let total = library.total {
                    footer("\(total) saved album\(total == 1 ? "" : "s"). Playing one needs Spotify Premium.")
                }
            }
            .task { if library.albums.isEmpty { await library.loadMore() } }
            .task(id: search) {
                // Searching covers the whole library, not just the pages loaded so far.
                while !search.isEmpty && library.hasMore && library.error == nil && !Task.isCancelled {
                    await library.loadMore()
                }
            }
            .refreshable {
                library.reset()
                await library.loadMore()
            }
        }
    }

    // MARK: Helpers

    private func footer(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 30)
            .padding(.bottom, 30)
    }

    private func matches(_ title: String, _ artist: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return title.localizedCaseInsensitiveContains(query) || artist.localizedCaseInsensitiveContains(query)
    }

    private func isPlaying(_ uri: String?) -> Bool {
        guard let uri, let current = nowPlaying.now.track?.albumURI else { return false }
        return uri == current && nowPlaying.now.state == .playing
    }

    private func play(_ uri: String?) {
        guard let uri else {
            nowPlaying.notice = "Play this album once more and Vinyl will be able to start it from here."
            return
        }
        guard starting == nil else { return }
        starting = uri
        Task {
            let ok = await nowPlaying.playAlbum(uri: uri)
            starting = nil
            if ok { dismiss() }
        }
    }
}

// MARK: - Cells

struct AlbumCell: View {
    enum Cover {
        case file(URL)
        case remote(URL?)
    }

    let title: String
    let artist: String
    let cover: Cover
    let isPlaying: Bool
    let isStarting: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                CoverImage(cover: cover)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                    .overlay(alignment: .bottomTrailing) {
                        if isStarting {
                            ProgressView()
                                .padding(8)
                                .background(.ultraThinMaterial, in: Circle())
                                .padding(8)
                        } else if isPlaying {
                            Image(systemName: "waveform")
                                .font(.caption.weight(.bold))
                                .padding(8)
                                .background(.ultraThinMaterial, in: Circle())
                                .padding(8)
                        }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) by \(artist)")
        .accessibilityHint("Plays the album")
        .accessibilityAddTraits(.isButton)
    }
}

/// Covers from the artwork cache load from disk; library covers from Spotify.
struct CoverImage: View {
    let cover: AlbumCell.Cover
    @State private var image: UIImage?

    var body: some View {
        switch cover {
        case .remote(let url):
            AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    placeholder
                }
            }
        case .file(let url):
            ZStack {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    placeholder
                }
            }
            .task(id: url) {
                image = await Task.detached(priority: .userInitiated) {
                    UIImage(contentsOfFile: url.path)?.preparingThumbnail(of: CGSize(width: 480, height: 480))
                }.value
            }
        }
    }

    private var placeholder: some View {
        ZStack {
            Color(white: 0.14)
            Image(systemName: "record.circle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
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
