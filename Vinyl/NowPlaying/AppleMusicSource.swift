import Foundation
import MediaPlayer
import UIKit

/// Apple Music playing on this device, through the system music player.
/// (iOS doesn't let apps see other apps' audio, so this only covers the Music app.)
@MainActor
final class AppleMusicSource {
    /// Called whenever the snapshot may have changed.
    var onChange: (() -> Void)?
    private(set) var snapshot: PlayerSnapshot = .stopped

    private var player: MPMusicPlayerController?
    private var observers: [NSObjectProtocol] = []
    private var pollTask: Task<Void, Never>?

    static var isAuthorized: Bool { MPMediaLibrary.authorizationStatus() == .authorized }

    static func requestAccess() async -> Bool {
        if isAuthorized { return true }
        return await withCheckedContinuation { continuation in
            MPMediaLibrary.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    var isRunning: Bool { player != nil }

    func start() {
        guard player == nil, Self.isAuthorized else { return }
        let player = MPMusicPlayerController.systemMusicPlayer
        self.player = player
        player.beginGeneratingPlaybackNotifications()
        let center = NotificationCenter.default
        for name in [Notification.Name.MPMusicPlayerControllerNowPlayingItemDidChange,
                     .MPMusicPlayerControllerPlaybackStateDidChange] {
            observers.append(center.addObserver(forName: name, object: player, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        // Notifications cover track and state changes; this catches seeks.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self?.refresh()
            }
        }
        refresh()
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        player?.endGeneratingPlaybackNotifications()
        player = nil
        snapshot = .stopped
        onChange?()
    }

    func refresh() {
        guard let player else { return }
        let next: PlayerSnapshot
        if let item = player.nowPlayingItem {
            let state: PlaybackState
            switch player.playbackState {
            case .playing, .seekingForward, .seekingBackward: state = .playing
            case .paused, .interrupted: state = .paused
            case .stopped: state = .stopped
            @unknown default: state = .paused
            }
            let position = player.currentPlaybackTime
            next = PlayerSnapshot(
                track: Self.track(from: item),
                state: state,
                position: position.isFinite ? max(0, position) : 0,
                positionDate: Date(),
                device: nil
            )
        } else {
            next = .stopped
        }
        guard !next.isClose(to: snapshot) else { return }
        snapshot = next
        onChange?()
    }

    /// The cover embedded in the playing item, if it has one.
    func embeddedArtwork() -> Data? {
        guard let artwork = player?.nowPlayingItem?.artwork,
              let image = artwork.image(at: CGSize(width: 1024, height: 1024))
        else { return nil }
        return image.jpegData(compressionQuality: 0.92)
    }

    // MARK: Controls

    func togglePlayPause() {
        guard let player else { return }
        if player.playbackState == .playing { player.pause() } else { player.play() }
        refreshSoon()
    }

    func play() { player?.play(); refreshSoon() }
    func pause() { player?.pause(); refreshSoon() }
    func next() { player?.skipToNextItem(); refreshSoon() }

    func previous() {
        guard let player else { return }
        // Like the Music app: restart the song unless we're right at its start.
        if player.currentPlaybackTime > 3 { player.skipToBeginning() } else { player.skipToPreviousItem() }
        refreshSoon()
    }

    /// An album's songs from the Music library, in disc and track order.
    static func albumItems(persistentID: UInt64) -> [MPMediaItem] {
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(MPMediaPropertyPredicate(
            value: NSNumber(value: persistentID),
            forProperty: MPMediaItemPropertyAlbumPersistentID
        ))
        return (query.items ?? []).sorted {
            ($0.discNumber, $0.albumTrackNumber) < ($1.discNumber, $1.albumTrackNumber)
        }
    }

    static func albumDetail(persistentID: UInt64) -> AlbumDetail? {
        let items = albumItems(persistentID: persistentID)
        guard let first = items.first else { return nil }
        let albumArtist = first.albumArtist ?? first.artist ?? ""
        return AlbumDetail(
            title: first.albumTitle ?? "",
            artist: albumArtist,
            year: first.releaseDate.map { String(Calendar.current.component(.year, from: $0)) },
            tracks: items.map { item in
                AlbumTrack(
                    id: "am:\(item.persistentID)",
                    number: item.albumTrackNumber,
                    disc: max(1, item.discNumber),
                    title: item.title ?? "",
                    artist: item.artist == albumArtist ? nil : item.artist,
                    duration: item.playbackDuration
                )
            }
        )
    }

    /// Queues an album from the Music library and plays it from track 1, or
    /// from `trackID`. False when it's no longer in the library.
    func playAlbum(persistentID: UInt64, startingAt trackID: String? = nil) -> Bool {
        guard let player else { return false }
        let items = Self.albumItems(persistentID: persistentID)
        guard !items.isEmpty else { return false }
        player.setQueue(with: MPMediaItemCollection(items: items))
        if let trackID, let start = items.first(where: { "am:\($0.persistentID)" == trackID }) {
            player.nowPlayingItem = start
        }
        player.play()
        refreshSoon()
        return true
    }

    func seek(to seconds: TimeInterval) {
        player?.currentPlaybackTime = seconds
        refreshSoon()
    }

    private func refreshSoon() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            self?.refresh()
        }
    }

    private static func track(from item: MPMediaItem) -> Track {
        Track(
            id: "am:\(item.persistentID)",
            title: item.title ?? "",
            artist: item.artist ?? "",
            album: item.albumTitle ?? "",
            albumArtist: item.albumArtist,
            duration: item.playbackDuration > 0 ? item.playbackDuration : nil,
            source: .appleMusic,
            artworkURL: nil,
            albumURI: item.albumPersistentID != 0 ? "am-album:\(item.albumPersistentID)" : nil
        )
    }
}
