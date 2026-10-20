import Foundation
import WidgetKit

/// Keeps the Home Screen and Lock Screen widgets in step with the app: saves
/// what's playing to the shared keychain and asks WidgetKit to redraw, but
/// only when something a widget shows has changed (song, play/pause, a seek),
/// never on every poll. Reloads requested by the app don't count against the
/// widgets' daily refresh budget.
@MainActor
enum WidgetBridge {
    private static var pending: Task<Void, Never>?
    private static var lastKey: String?
    private static var artworkCache: (file: String, data: Data?)?

    /// Coalesces a burst of changes (track, then artwork, then state) into one update.
    static func publish() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            publishNow()
        }
    }

    static func publishNow() {
        let service = NowPlayingService.shared
        let now = service.now
        guard let track = now.track else {
            if lastKey != "none" {
                lastKey = "none"
                NowPlayingSnapshot.save(nil)
                WidgetCenter.shared.reloadAllTimelines()
            }
            return
        }
        let position = now.position(at: Date())
        // Steady playback keeps the start time constant; a seek or a pause changes the key.
        let startedAt = Date().timeIntervalSince1970 - position
        let style = Preferences.shared.vinylStyle.rawValue
        let spin = Preferences.shared.widgetSpin
        let key = [track.id, now.state.rawValue, String(Int(startedAt / 3)), style, String(spin),
                   service.artworkPending ? "" : (service.artworkFile ?? "")].joined(separator: "|")
        guard key != lastKey else { return }
        lastKey = key

        NowPlayingSnapshot.save(NowPlayingSnapshot(
            trackID: track.id,
            title: track.title,
            artist: track.artist,
            album: track.album,
            albumKey: track.albumKey,
            source: track.source.displayName,
            device: now.device,
            isPlaying: now.state == .playing,
            position: position,
            positionDate: Date(),
            duration: track.duration ?? 0,
            artwork: service.artworkPending ? nil : artwork(forFile: service.artworkFile),
            vinylStyle: style,
            widgetSpin: spin
        ))
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// A ~360 px cover: sharp on a large iPad widget, small enough for the keychain.
    private static func artwork(forFile file: String?) -> Data? {
        guard let file else { return nil }
        if let artworkCache, artworkCache.file == file { return artworkCache.data }
        let data = (try? Data(contentsOf: ArtworkStore.shared.url(forFile: file)))
            .flatMap { ArtworkStore.jpeg(from: $0, maxPixel: 360, quality: 0.82) }
        artworkCache = (file, data)
        return data
    }
}
