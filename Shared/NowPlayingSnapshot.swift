import Foundation

/// What's playing, as the app last saw it, left in the shared keychain for
/// the widgets. Covers Apple Music (which only the app can see) and gives
/// the widgets something to show instantly before they ask Spotify.
struct NowPlayingSnapshot: Codable, Equatable {
    var trackID: String
    var title: String
    var artist: String
    var album: String
    var albumKey: String
    /// "Spotify" or "Apple Music".
    var source: String
    var device: String?
    var isPlaying: Bool
    /// Seconds into the song at `positionDate`.
    var position: TimeInterval
    var positionDate: Date
    /// Seconds; 0 when unknown.
    var duration: TimeInterval
    /// A small JPEG of the cover.
    var artwork: Data?
    /// The app's Record setting (`VinylStyle` raw value), so widgets match it.
    var vinylStyle: String?
    /// The app's "Spin the Record in Widgets" setting.
    var widgetSpin: Bool?

    func position(at date: Date) -> TimeInterval {
        let p = isPlaying ? position + date.timeIntervalSince(positionDate) : position
        return duration > 0 ? min(p, duration) : p
    }

    /// Still playing, by the clock: a song that should have ended has an unknown successor.
    func isCurrent(at date: Date) -> Bool {
        !isPlaying || duration == 0 || position(at: date) < duration - 0.5
    }

    private static let account = "nowPlaying"

    static func load() -> NowPlayingSnapshot? {
        Keychain.read(account).flatMap { try? JSONDecoder().decode(NowPlayingSnapshot.self, from: $0) }
    }

    static func save(_ snapshot: NowPlayingSnapshot?) {
        if let snapshot, let data = try? JSONEncoder().encode(snapshot) {
            Keychain.write(data, for: account)
        } else {
            Keychain.delete(account)
        }
    }
}
