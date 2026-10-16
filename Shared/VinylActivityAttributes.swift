import ActivityKit
import Foundation

/// The Lock Screen / Dynamic Island Live Activity. Compiled into both the app
/// and the widget extension.
struct VinylActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var artist: String
        var album: String
        var isPlaying: Bool
        /// When the track started (or would have, given the current position),
        /// so the widget can run its progress bar without updates from the app.
        var startedAt: Date
        /// Seconds; 0 when unknown.
        var duration: TimeInterval
        /// Position to show while paused.
        var pausedPosition: TimeInterval
        /// "Spotify" or "Apple Music".
        var source: String
        /// Spotify's device name ("Kitchen", "MacBook Pro"), when known.
        var device: String?
        /// A tiny JPEG of the cover. Live Activity updates are capped at 4 KB,
        /// and the extension can't load images from the network.
        var artwork: Data?

        var endsAt: Date { startedAt.addingTimeInterval(duration) }
    }
}
