import SwiftUI

@main
struct VinylApp: App {
    @StateObject private var prefs = Preferences.shared
    @StateObject private var nowPlaying = NowPlayingService.shared
    @StateObject private var spotify = SpotifyAuth.shared

    init() {
        // Adopts a Live Activity left running from the last launch.
        _ = LiveActivityController.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(prefs)
                .environmentObject(nowPlaying)
                .environmentObject(spotify)
                .preferredColorScheme(.dark)
        }
    }
}
