import SwiftUI

/// Track info, a scrubber and transport buttons. Appears on tap, hides itself.
struct ControlsOverlay: View {
    @EnvironmentObject private var nowPlaying: NowPlayingService
    let visible: Bool
    let openCrate: () -> Void
    let openSettings: () -> Void
    /// Any touch here keeps the overlay up a little longer.
    let interacted: () -> Void

    var body: some View {
        VStack {
            HStack(spacing: 12) {
                Spacer()
                Button(action: { interacted(); openCrate() }) {
                    Label("Crate", systemImage: "square.grid.2x2.fill")
                        .font(.headline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .accessibilityLabel("Crate: your albums")
                Button(action: { interacted(); openSettings() }) {
                    Image(systemName: "gearshape.fill")
                        .font(.title3)
                        .padding(12)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Settings")
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)

            Spacer()

            VStack(spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(nowPlaying.now.track?.title ?? "Nothing playing")
                            .font(.headline)
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 12)
                }

                if let duration = nowPlaying.now.track?.duration, duration > 0 {
                    Scrubber(duration: duration, interacted: interacted)
                }

                HStack(spacing: 44) {
                    transportButton("backward.fill", label: "Previous") { await nowPlaying.perform(.previous) }
                    transportButton(nowPlaying.now.state == .playing ? "pause.fill" : "play.fill",
                                    label: nowPlaying.now.state == .playing ? "Pause" : "Play",
                                    size: .largeTitle) { await nowPlaying.perform(.toggle) }
                    transportButton("forward.fill", label: "Next") { await nowPlaying.perform(.next) }
                }
                .disabled(nowPlaying.now.track == nil && nowPlaying.activeSource == nil && !nowPlaying.hasAnySource)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .frame(maxWidth: 620)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .foregroundStyle(.white)
    }

    private var subtitle: String {
        guard let track = nowPlaying.now.track else {
            return nowPlaying.hasAnySource ? "Start something in Spotify or Apple Music" : "Connect a player in Settings"
        }
        var parts = [track.artist]
        if let device = nowPlaying.now.device, !device.isEmpty {
            parts.append("\(track.source.displayName) on \(device)")
        } else {
            parts.append(track.source.displayName)
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func transportButton(_ symbol: String, label: String, size: Font = .title2, action: @escaping () async -> Void) -> some View {
        Button {
            interacted()
            Task { await action() }
        } label: {
            Image(systemName: symbol)
                .font(size)
                .frame(width: 54, height: 54)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// A progress bar you can drag to seek.
struct Scrubber: View {
    @EnvironmentObject private var nowPlaying: NowPlayingService
    let duration: TimeInterval
    let interacted: () -> Void
    @State private var scrubbing: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let position = scrubbing ?? min(duration, nowPlaying.now.position(at: context.date))
            VStack(spacing: 6) {
                GeometryReader { geo in
                    let fraction = duration > 0 ? position / duration : 0
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.22))
                        Capsule().fill(.white).frame(width: max(4, geo.size.width * fraction))
                    }
                    .frame(height: scrubbing == nil ? 5 : 9)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                interacted()
                                scrubbing = min(max(0, value.location.x / geo.size.width), 1) * duration
                            }
                            .onEnded { _ in
                                if let target = scrubbing {
                                    Task {
                                        await nowPlaying.seek(to: target)
                                        scrubbing = nil
                                    }
                                }
                            }
                    )
                }
                .frame(height: 18)
                .animation(.easeOut(duration: 0.15), value: scrubbing == nil)
                HStack {
                    Text(Self.format(position))
                    Spacer()
                    Text("-" + Self.format(max(0, duration - position)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Song position")
        .accessibilityValue(Self.format(nowPlaying.now.position()))
    }

    static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
