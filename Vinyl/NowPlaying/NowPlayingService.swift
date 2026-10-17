import Combine
import Foundation
import os

enum PlaybackCommand {
    case toggle, play, pause, next, previous
}

/// Combines Spotify (Web API, any device) and Apple Music (this device) into
/// one "now playing", resolves artwork, keeps the recent-albums stack and
/// routes playback commands to whichever player is showing.
@MainActor
final class NowPlayingService: ObservableObject {
    static let shared = NowPlayingService()

    @Published private(set) var now: PlayerSnapshot = .stopped
    @Published private(set) var artworkFile: String?
    @Published private(set) var artworkPending = false
    @Published private(set) var recent: [RecentAlbum] = []
    /// A short message to show briefly (e.g. "Spotify needs Premium for controls").
    @Published var notice: String?

    private let prefs = Preferences.shared
    private let spotifyAuth = SpotifyAuth.shared
    private let appleMusic = AppleMusicSource()
    private var spotify: PlayerSnapshot = .stopped
    /// Spotify's current limits on remote control, from the last poll.
    private var spotifyControl = SpotifyControl()
    private var spotifyTask: Task<Void, Never>?
    private var spotifyWake: CheckedContinuation<Void, Never>?
    private var wakeToken = 0
    private var spotifyBackoffUntil = Date.distantPast
    private var lastPlayingSource: PlayerSource?
    private var lastStates: [PlayerSource: PlaybackState] = [:]
    private var artworkKey: String?
    private var active = false
    private var cancellables = Set<AnyCancellable>()
    private let log = Logger(subsystem: "io.github.cyclonedraco.vinyl.ios", category: "NowPlaying")

    private init() {
        if let data = UserDefaults.standard.data(forKey: "recentAlbums"),
           let saved = try? JSONDecoder().decode([RecentAlbum].self, from: data) {
            recent = saved.filter { FileManager.default.fileExists(atPath: ArtworkStore.shared.url(forFile: $0.artworkFile).path) }
        }
        appleMusic.onChange = { [weak self] in self?.recompute() }

        spotifyAuth.$isConnected
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] connected in
                guard let self else { return }
                if connected { self.startSpotifyIfNeeded() } else { self.stopSpotify() }
            }
            .store(in: &cancellables)

        prefs.$appleMusicEnabled
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled && self.active { self.appleMusic.start() }
                if !enabled { self.appleMusic.stop() }
            }
            .store(in: &cancellables)

        prefs.$source
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.recompute() }
            }
            .store(in: &cancellables)
    }

    var activeSource: PlayerSource? { now.track?.source }
    var hasAnySource: Bool { spotifyAuth.isConnected || (prefs.appleMusicEnabled && AppleMusicSource.isAuthorized) }

    // MARK: Lifecycle

    /// Polls while the app is on screen; iOS suspends it in the background anyway.
    func setActive(_ isActive: Bool) {
        guard isActive != active else { return }
        active = isActive
        if isActive {
            if prefs.appleMusicEnabled { appleMusic.start() }
            startSpotifyIfNeeded()
        } else {
            stopSpotify()
            appleMusic.stop()
        }
    }

    /// One-shot refresh of every source, for Live Activity buttons that run
    /// while the app is in the background.
    func refreshOnce() async {
        if prefs.appleMusicEnabled && !appleMusic.isRunning { appleMusic.start() }
        appleMusic.refresh()
        if spotifyAuth.isConnected { _ = await pollSpotify() }
    }

    // MARK: Spotify polling

    private func startSpotifyIfNeeded() {
        guard active, spotifyAuth.isConnected, spotifyTask == nil else { return }
        spotifyTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let delay = await self.pollSpotify()
                await self.sleep(seconds: delay)
            }
        }
    }

    private func stopSpotify() {
        spotifyTask?.cancel()
        spotifyTask = nil
        wakeSpotify()
        if !spotifyAuth.isConnected, spotify != .stopped {
            spotify = .stopped
            recompute()
        }
    }

    /// Sleeps until the delay passes or `wakeSpotify()` is called.
    private func sleep(seconds: TimeInterval) async {
        wakeToken += 1
        let token = wakeToken
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            spotifyWake = continuation
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0.2, seconds) * 1_000_000_000))
                // A timer left over from an earlier, already-woken sleep does nothing.
                guard let self, self.wakeToken == token else { return }
                self.wakeSpotify()
            }
        }
    }

    private func wakeSpotify() {
        guard let pending = spotifyWake else { return }
        spotifyWake = nil
        pending.resume()
    }

    /// Asks for a fresh poll now (after a command, or when the app comes back).
    func pollSpotifySoon() { wakeSpotify() }

    /// Polls once and returns how long to wait before the next poll. The
    /// cadence keeps one user far below Spotify's rate limits: every 5 s while
    /// playing (plus right when the song should end), slower when idle.
    private func pollSpotify() async -> TimeInterval {
        if Date() < spotifyBackoffUntil { return spotifyBackoffUntil.timeIntervalSinceNow }
        do {
            let playback = try await SpotifyAPI.shared.playback()
            spotifyControl = playback?.control ?? SpotifyControl()
            let next: PlayerSnapshot
            if let playback, let track = playback.track, !track.isAdvertisement {
                next = PlayerSnapshot(
                    track: track,
                    state: playback.isPlaying ? .playing : .paused,
                    position: playback.progress,
                    positionDate: playback.fetchedAt,
                    device: playback.device
                )
            } else if let playback, playback.track == nil, playback.isPlaying {
                // An ad (or something without metadata) is playing: keep the last record on.
                next = spotify
            } else {
                next = .stopped
            }
            if !next.isClose(to: spotify) {
                spotify = next
                recompute()
            }
            switch next.state {
            case .playing:
                if let duration = next.track?.duration, duration > 0 {
                    let remaining = duration - next.position(at: Date())
                    return min(5, max(1, remaining + 0.6))
                }
                return 5
            case .paused: return 6
            case .stopped: return 10
            }
        } catch SpotifyAPIError.rateLimited(let wait) {
            spotifyBackoffUntil = Date().addingTimeInterval(wait + 1)
            return wait + 1
        } catch SpotifyAPIError.notConnected {
            return 30
        } catch {
            log.debug("poll failed: \(error.localizedDescription, privacy: .public)")
            return 10
        }
    }

    // MARK: Combining

    private func recompute() {
        let apple = appleMusic.snapshot
        // Whichever player started most recently wins when both are playing.
        for (source, snap) in [(PlayerSource.spotify, spotify), (.appleMusic, apple)] {
            if snap.state == .playing && lastStates[source] != .playing { lastPlayingSource = source }
            lastStates[source] = snap.state
        }
        let chosen: PlayerSnapshot
        switch prefs.source {
        case .spotify: chosen = spotify
        case .appleMusic: chosen = apple
        case .automatic:
            switch (spotify.state == .playing, apple.state == .playing) {
            case (true, false): chosen = spotify
            case (false, true): chosen = apple
            default:
                let preferApple = lastPlayingSource == .appleMusic
                let first = preferApple ? apple : spotify
                let second = preferApple ? spotify : apple
                chosen = first.track != nil ? first : second
            }
        }
        if chosen != now { now = chosen }
        resolveArtwork(for: chosen.track)
        LiveActivityController.shared.scheduleSync()
    }

    private func resolveArtwork(for track: Track?) {
        guard let track else {
            artworkKey = nil
            artworkPending = false
            return
        }
        let key = track.albumKey
        guard key != artworkKey else { return }
        artworkKey = key
        artworkPending = true
        let embedded = track.source == .appleMusic ? appleMusic.embeddedArtwork() : nil
        Task { [weak self] in
            let file = await ArtworkStore.shared.artwork(for: track, embedded: embedded)
            guard let self, self.artworkKey == key else { return }
            self.artworkFile = file
            self.artworkPending = false
            if let file { self.remember(track, artworkFile: file) }
            LiveActivityController.shared.scheduleSync()
        }
    }

    private func remember(_ track: Track, artworkFile: String) {
        let album = RecentAlbum(
            key: track.albumKey,
            title: track.album.isEmpty ? track.title : track.album,
            artist: track.albumArtist ?? track.artist,
            artworkFile: artworkFile,
            albumURI: track.albumURI ?? recent.first { $0.key == track.albumKey }?.albumURI,
            lastPlayed: Date()
        )
        var list = recent.filter { $0.key != album.key }
        list.insert(album, at: 0)
        // The Crate's history; matches the artwork cache's 300 covers.
        recent = Array(list.prefix(300))
        if let data = try? JSONEncoder().encode(recent) {
            UserDefaults.standard.set(data, forKey: "recentAlbums")
        }
    }

    // MARK: Commands

    func perform(_ command: PlaybackCommand) async {
        guard let source = now.track?.source ?? (spotifyAuth.isConnected ? .spotify : nil) else { return }
        var command = command
        if command == .toggle, source == .spotify {
            // Decide play vs pause before the optimistic update below flips the state.
            command = spotifyIsPlaying ? .pause : .play
        }
        if source == .spotify {
            // Spotify refuses play while playing and pause while paused, so
            // asking for the state it's already in is simply done.
            if command == .play && spotifyIsPlaying { return }
            if command == .pause && !spotifyIsPlaying { return }
        }
        // Show the result right away; the next poll confirms it.
        applyOptimistically(command)
        switch source {
        case .appleMusic:
            switch command {
            case .toggle: appleMusic.togglePlayPause()
            case .play: appleMusic.play()
            case .pause: appleMusic.pause()
            case .next: appleMusic.next()
            case .previous: appleMusic.previous()
            }
        case .spotify:
            do {
                switch command {
                case .toggle, .play: try await SpotifyAPI.shared.play() // (toggle is resolved above)
                case .pause: try await SpotifyAPI.shared.pause()
                case .next: try await SpotifyAPI.shared.next()
                case .previous: try await SpotifyAPI.shared.previous()
                }
            } catch {
                notice = describe(error)
            }
            try? await Task.sleep(nanoseconds: 450_000_000)
            if spotifyTask != nil { pollSpotifySoon() } else { _ = await pollSpotify() }
        }
    }

    /// An album's tracklist. `uri` is a `Track.albumURI`.
    func albumDetail(uri: String) async throws -> AlbumDetail? {
        if uri.hasPrefix("spotify:") { return try await SpotifyAPI.shared.album(uri: uri) }
        if uri.hasPrefix("am-album:"), let id = UInt64(uri.dropFirst("am-album:".count)) {
            return AppleMusicSource.albumDetail(persistentID: id)
        }
        return nil
    }

    /// Plays a whole album from track 1, or from `trackID` (an `AlbumTrack.id`).
    /// `uri` is a `Track.albumURI`. Returns false (and sets `notice`) when it couldn't.
    @discardableResult
    func playAlbum(uri: String, startingAt trackID: String? = nil) async -> Bool {
        if uri.hasPrefix("spotify:") {
            do {
                try await SpotifyAPI.shared.play(contextURI: uri, startingAt: trackID)
            } catch {
                notice = describe(error)
                return false
            }
            try? await Task.sleep(nanoseconds: 600_000_000)
            if spotifyTask != nil { pollSpotifySoon() } else { _ = await pollSpotify() }
            return true
        }
        if uri.hasPrefix("am-album:"), let id = UInt64(uri.dropFirst("am-album:".count)) {
            if !appleMusic.isRunning { appleMusic.start() }
            guard appleMusic.playAlbum(persistentID: id, startingAt: trackID) else {
                notice = "That album isn't in your Apple Music library any more."
                return false
            }
            return true
        }
        return false
    }

    func seek(to seconds: TimeInterval) async {
        guard let track = now.track else { return }
        switch track.source {
        case .appleMusic:
            appleMusic.seek(to: seconds)
        case .spotify:
            spotify.position = seconds
            spotify.positionDate = Date()
            recompute()
            do { try await SpotifyAPI.shared.seek(to: seconds) } catch { notice = describe(error) }
            pollSpotifySoon()
        }
    }

    /// Spotify's own word wins: it disallows "pausing" exactly when paused and
    /// "resuming" exactly when playing. Falls back to the last polled state.
    private var spotifyIsPlaying: Bool {
        if spotifyControl.disallows.contains("pausing") { return false }
        if spotifyControl.disallows.contains("resuming") { return true }
        return spotify.state == .playing
    }

    /// A Spotify "restriction violated" becomes the actual limit from the last poll.
    private func describe(_ error: Error) -> String {
        if case SpotifyAPIError.forbidden(let message) = error,
           message.localizedCaseInsensitiveContains("restriction") {
            return spotifyControl.explanation(device: spotify.device)
        }
        return error.localizedDescription
    }

    private func applyOptimistically(_ command: PlaybackCommand) {
        guard now.track?.source == .spotify else { return }
        let position = spotify.position(at: Date())
        switch command {
        case .toggle: spotify.state = spotify.state == .playing ? .paused : .playing
        case .play: spotify.state = .playing
        case .pause: spotify.state = .paused
        case .next, .previous: return
        }
        spotify.position = position
        spotify.positionDate = Date()
        recompute()
    }
}

/// Entry point for the Live Activity buttons (see `PlaybackIntents.swift`).
@MainActor
enum PlaybackCommandCenter {
    static func perform(_ command: PlaybackCommand) async {
        let service = NowPlayingService.shared
        // Launched in the background just for this: learn what's playing first,
        // so "toggle" knows which way to go.
        if service.now.track == nil || Date().timeIntervalSince(service.now.positionDate) > 8 {
            await service.refreshOnce()
        }
        await service.perform(command)
        try? await Task.sleep(nanoseconds: 700_000_000)
        await service.refreshOnce()
        await LiveActivityController.shared.sync()
    }
}
