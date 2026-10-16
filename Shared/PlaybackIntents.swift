import AppIntents

// Buttons on the Live Activity. `LiveActivityIntent`s always run in the app's
// process (launched in the background if needed), so the widget extension
// compiles them with an empty body.

struct TogglePlaybackIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Play or Pause"
    static var description = IntentDescription("Plays or pauses the music Vinyl is showing.")

    init() {}

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await PlaybackCommandCenter.perform(.toggle)
        #endif
        return .result()
    }
}

struct NextTrackIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Next Track"
    static var description = IntentDescription("Skips to the next track.")

    init() {}

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await PlaybackCommandCenter.perform(.next)
        #endif
        return .result()
    }
}

struct PreviousTrackIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Previous Track"
    static var description = IntentDescription("Goes back to the previous track.")

    init() {}

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await PlaybackCommandCenter.perform(.previous)
        #endif
        return .result()
    }
}
