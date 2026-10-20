import ActivityKit
import AppIntents
import SwiftUI
import UIKit
import WidgetKit

@main
struct VinylWidgetsBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingLiveActivity()
        NowPlayingWidget()
    }
}

struct NowPlayingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VinylActivityAttributes.self) { context in
            LockScreenView(state: context.state, isStale: context.isStale)
                .activityBackgroundTint(Color.black.opacity(0.72))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    RecordBadge(artwork: state.artwork, size: 58)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.title).font(.headline).lineLimit(1)
                        Text(state.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Button(intent: TogglePlaybackIntent()) {
                        Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        ProgressRow(state: state, isStale: context.isStale)
                        TransportRow(state: state)
                    }
                    .padding(.horizontal, 6)
                }
            } compactLeading: {
                RecordBadge(artwork: state.artwork, size: 24)
            } compactTrailing: {
                if state.isPlaying && state.duration > 0 && !context.isStale {
                    Text(timerInterval: state.startedAt...state.endsAt, countsDown: true)
                        .monospacedDigit()
                        .font(.caption2)
                        .frame(maxWidth: 40)
                } else {
                    Image(systemName: state.isPlaying ? "waveform" : "pause.fill")
                        .font(.caption)
                }
            } minimal: {
                RecordBadge(artwork: state.artwork, size: 24)
            }
            .keylineTint(.white)
        }
    }
}

struct LockScreenView: View {
    let state: VinylActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        HStack(spacing: 14) {
            RecordBadge(artwork: state.artwork, size: 74)
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                ProgressRow(state: state, isStale: isStale)
                TransportRow(state: state)
            }
        }
        .padding(16)
        .foregroundStyle(.white)
    }

    private var subtitle: String {
        if isStale { return "\(state.artist) · Open Vinyl to refresh" }
        if let device = state.device, !device.isEmpty { return "\(state.artist) · \(device)" }
        return state.artist
    }
}

/// Runs on its own from the start time, so it keeps moving between updates.
struct ProgressRow: View {
    let state: VinylActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        if state.duration > 0 {
            if state.isPlaying && !isStale {
                ProgressView(timerInterval: state.startedAt...state.endsAt, countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
                .tint(.white)
            } else {
                ProgressView(value: min(state.pausedPosition, state.duration), total: state.duration)
                    .tint(.white.opacity(0.7))
            }
        }
    }
}

struct TransportRow: View {
    let state: VinylActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 0) {
            Button(intent: PreviousTrackIntent()) {
                Image(systemName: "backward.fill").frame(maxWidth: .infinity)
            }
            Button(intent: TogglePlaybackIntent()) {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(maxWidth: .infinity)
            }
            Button(intent: NextTrackIntent()) {
                Image(systemName: "forward.fill").frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }
}

/// A small record with the cover as its label.
struct RecordBadge: View {
    let artwork: Data?
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(Color(white: 0.06))
            ForEach(0..<4) { i in
                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.6)
                    .padding(size * (0.06 + CGFloat(i) * 0.06))
            }
            Group {
                if let artwork, let image = UIImage(data: artwork) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color(red: 0.84, green: 0.49, blue: 0.21)
                }
            }
            .frame(width: size * 0.46, height: size * 0.46)
            .clipShape(Circle())
            Circle()
                .fill(Color.black)
                .frame(width: max(2, size * 0.05), height: max(2, size * 0.05))
        }
        .frame(width: size, height: size)
    }
}
