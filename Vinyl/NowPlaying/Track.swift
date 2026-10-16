import Foundation

enum PlayerSource: String, CaseIterable, Identifiable, Codable {
    case spotify
    case appleMusic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .spotify: return "Spotify"
        case .appleMusic: return "Apple Music"
        }
    }
}

enum PlaybackState: String, Codable {
    case playing, paused, stopped
}

struct Track: Equatable, Codable {
    /// `spotify:track:…` for Spotify, `am:<persistent ID>` for Apple Music.
    var id: String
    var title: String
    var artist: String
    var album: String
    var albumArtist: String?
    /// Seconds, when the player reports it.
    var duration: TimeInterval?
    var source: PlayerSource
    /// Cover art URL straight from the player's API (Spotify), when known.
    var artworkURL: URL?
    /// What plays the whole album: `spotify:album:…` or `am-album:<persistent ID>`.
    var albumURI: String? = nil

    /// Identifies the album, used to cache artwork and build the recent stack.
    var albumKey: String {
        let who = (albumArtist?.isEmpty == false ? albumArtist! : artist)
        let what = album.isEmpty ? title : album
        return "\(source.rawValue)|\(who)|\(what)".lowercased()
    }

    /// Spotify ads don't have real metadata.
    var isAdvertisement: Bool { id.hasPrefix("spotify:ad:") }
}

/// What one player is doing, as last reported.
struct PlayerSnapshot: Equatable {
    var track: Track?
    var state: PlaybackState
    var position: TimeInterval
    var positionDate: Date
    /// Where Spotify is playing ("Kitchen speaker"); nil for this device.
    var device: String?

    static let stopped = PlayerSnapshot(track: nil, state: .stopped, position: 0, positionDate: .distantPast, device: nil)

    func position(at date: Date = Date()) -> TimeInterval {
        guard state == .playing else { return position }
        let p = position + date.timeIntervalSince(positionDate)
        if let d = track?.duration, d > 0 { return min(p, d) }
        return p
    }

    /// Same track, state and (extrapolated) position within a second.
    func isClose(to other: PlayerSnapshot) -> Bool {
        track == other.track && state == other.state && device == other.device
            && abs(position(at: Date()) - other.position(at: Date())) < 1.0
    }
}

/// An album played in Vinyl: the 3D scenes' sleeve stack and the Crate.
struct RecentAlbum: Codable, Equatable, Identifiable {
    var key: String
    var title: String
    var artist: String
    var artworkFile: String
    /// Plays the album from the start (see `Track.albumURI`). Older entries lack it.
    var albumURI: String?
    var lastPlayed: Date?
    var id: String { key }
}
