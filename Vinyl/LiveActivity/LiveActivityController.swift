import ActivityKit
import Foundation
import UIKit
import os

/// Mirrors "now playing" onto a Lock Screen / Dynamic Island Live Activity.
///
/// Updates come from the app itself (no push server), so they flow while
/// Vinyl is open or when a Live Activity button runs. In between, the widget
/// runs its own progress bar to the end of the song and then shows itself as
/// stale until Vinyl updates it again.
@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()

    private var activity: Activity<VinylActivityAttributes>?
    private var lastState: VinylActivityAttributes.ContentState?
    private var pending: Task<Void, Never>?
    private var endTask: Task<Void, Never>?
    private var thumbnail: (file: String, data: Data?)?
    private let log = Logger(subsystem: "io.github.cyclonedraco.vinyl.ios", category: "LiveActivity")

    private init() {
        // Adopt one left over from the last launch rather than starting a second.
        let existing = Activity<VinylActivityAttributes>.activities
        activity = existing.first
        for extra in existing.dropFirst() {
            Task { await extra.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// Live Activities exist on iPhone; iPad shows the full-screen scene instead.
    var isSupported: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// Coalesces bursts of changes (track + artwork + state) into one update.
    func scheduleSync() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    func sync() async {
        let prefs = Preferences.shared
        let service = NowPlayingService.shared
        guard prefs.liveActivity, isSupported else {
            await endAll()
            return
        }
        guard let track = service.now.track, service.now.state != .stopped else {
            // Brief gaps happen between songs; only end after a real stop.
            scheduleEnd(after: 90)
            return
        }
        endTask?.cancel()
        endTask = nil

        let snapshot = service.now
        let position = snapshot.position(at: Date())
        let duration = track.duration ?? 0
        let state = VinylActivityAttributes.ContentState(
            title: track.title,
            artist: track.artist,
            album: track.album,
            isPlaying: snapshot.state == .playing,
            startedAt: Date(timeIntervalSinceReferenceDate: (Date().timeIntervalSinceReferenceDate - position).rounded()),
            duration: duration,
            pausedPosition: position,
            source: track.source.displayName,
            device: snapshot.device,
            artwork: artworkThumbnail(service.artworkPending ? nil : service.artworkFile)
        )
        if let lastState, activity?.activityState == .active, Self.isEquivalent(lastState, state) { return }

        let stale: Date = state.isPlaying && duration > 0
            ? state.endsAt.addingTimeInterval(8)
            : Date().addingTimeInterval(30 * 60)
        let content = ActivityContent(state: state, staleDate: stale)

        if let activity, activity.activityState == .active {
            await activity.update(content)
            lastState = state
        } else {
            // Activities can only be started while the app is in the foreground.
            guard UIApplication.shared.applicationState != .background else { return }
            do {
                activity = try Activity.request(attributes: VinylActivityAttributes(), content: content, pushType: nil)
                lastState = state
            } catch {
                log.error("couldn't start Live Activity: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func endAll() async {
        endTask?.cancel()
        endTask = nil
        for activity in Activity<VinylActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        activity = nil
        lastState = nil
    }

    private func scheduleEnd(after seconds: TimeInterval) {
        guard endTask == nil, activity != nil else { return }
        endTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.endAll()
        }
    }

    private func artworkThumbnail(_ file: String?) -> Data? {
        guard let file else { return nil }
        if let thumbnail, thumbnail.file == file { return thumbnail.data }
        let data = ArtworkStore.shared.liveActivityThumbnail(forFile: file)
        thumbnail = (file, data)
        return data
    }

    /// Ignores the sub-second jitter in `startedAt` between polls.
    private static func isEquivalent(_ a: VinylActivityAttributes.ContentState, _ b: VinylActivityAttributes.ContentState) -> Bool {
        var a = a
        if abs(a.startedAt.timeIntervalSince(b.startedAt)) <= 2 { a.startedAt = b.startedAt }
        if !a.isPlaying, abs(a.pausedPosition - b.pausedPosition) <= 2 { a.pausedPosition = b.pausedPosition }
        if a.isPlaying { a.pausedPosition = b.pausedPosition }
        return a == b
    }
}
