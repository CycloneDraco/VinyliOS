import SwiftUI
import UIKit

/// The native scene: the album sleeve with its record slid out, pressed in
/// the album's colours, and a tonearm that tracks through the song.
///
/// Both are hands-on, like the real thing:
/// - **Record**: touch it and the platter stops under your finger; turn it to
///   scrub (one turn = 15 s), fling it and it carries on before the motor
///   takes back over. A quick tap plays or pauses.
/// - **Tonearm**: pick it up anywhere and it follows your finger. Drop it on
///   a groove to play from there; park it on its rest to pause.
struct SleeveSceneView: View {
    @EnvironmentObject private var nowPlaying: NowPlayingService
    @EnvironmentObject private var prefs: Preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    @State private var artwork: UIImage?
    /// Which artwork `artwork` and `palette` currently reflect.
    @State private var loadedArtworkKey = ""
    @State private var palette = AlbumPalette.neutral
    @State private var discImage: UIImage?

    @State private var spin = SpinModel()
    @State private var spinTimelineRunning = false
    @State private var platter: PlatterDrag?
    @State private var arm: ArmDrag?
    /// The arm was parked by hand; it stays on its rest until playback resumes.
    @State private var armParked = false
    /// Where a hand gesture sent the song, shown until the player catches up.
    @State private var pendingSeek: PendingSeek?

    /// One full turn of the record by hand moves this far through the song.
    private static let secondsPerTurn: Double = 15

    var body: some View {
        GeometryReader { geo in
            let layout = SleeveLayout(size: geo.size, captionSpace: prefs.showTrackInfo ? min(76, geo.size.height * 0.13) : 0)
            ZStack(alignment: .topLeading) {
                background
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()

                sleeve(layout)
                record(layout)

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    tonearm(layout, date: context.date)
                }

                if prefs.showTrackInfo {
                    caption
                        .frame(width: geo.size.width - 56, alignment: .leading)
                        .position(x: geo.size.width / 2, y: geo.size.height - 44)
                }
            }
            .coordinateSpace(.named(Self.stage))
            .task(id: discRenderKey(layout)) { renderDisc(diameter: layout.disc) }
        }
        .ignoresSafeArea()
        .task(id: artworkKey) { await loadArtwork() }
        .onAppear { updateSpin() }
        .onChange(of: spinTarget) { _, _ in updateSpin() }
        .onChange(of: nowPlaying.now) { _, now in
            if now.state == .playing { armParked = false }
            // Drop the hand-gesture override once the player agrees (or after a few seconds).
            if let pending = pendingSeek {
                let caughtUp = abs(now.position(at: Date()) - pending.position(at: Date(), playing: now.state == .playing)) < 2.5
                if caughtUp || Date() > pending.expires { pendingSeek = nil }
            }
        }
        .onChange(of: nowPlaying.now.track?.id) { _, _ in pendingSeek = nil }
    }

    private static let stage = "sleeve-stage"

    // MARK: Background

    @ViewBuilder
    private var background: some View {
        switch prefs.sleeveBackground {
        case .album:
            ZStack {
                palette.background.color
                // A soft pool of light behind the record, like a lamp on the desk.
                RadialGradient(colors: [.white.opacity(0.10), .clear], center: UnitPoint(x: 0.62, y: 0.42),
                               startRadius: 0, endRadius: 700)
                LinearGradient(colors: [.clear, .black.opacity(0.18)], startPoint: .top, endPoint: .bottom)
            }
            // Ease colour changes rather than jumping (no abrupt brightness shifts).
            .animation(.easeInOut(duration: 0.9), value: palette)
        case .cover:
            ZStack {
                Color.black
                if let artwork {
                    Image(uiImage: artwork)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 70, opaque: true)
                        .saturation(1.15)
                        .overlay(Color.black.opacity(0.38))
                        .transition(.opacity)
                        .id(loadedArtworkKey)
                }
            }
            .animation(.easeInOut(duration: 0.8), value: loadedArtworkKey)
        case .light:
            Color(red: 0.95, green: 0.94, blue: 0.92)
        case .dark:
            Color(white: 0.06)
        }
    }

    // MARK: Sleeve

    private func sleeve(_ layout: SleeveLayout) -> some View {
        ZStack {
            Image(uiImage: artwork ?? Self.idleCover)
                .resizable()
                .scaledToFill()
                .frame(width: layout.sleeve, height: layout.sleeve)
                .clipped()
                .transition(.opacity)
                .id(loadedArtworkKey)
            // Faint gloss, like printed card.
            LinearGradient(colors: [.white.opacity(0.10), .clear, .black.opacity(0.10)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .frame(width: layout.sleeve, height: layout.sleeve)
        .clipShape(RoundedRectangle(cornerRadius: layout.sleeve * 0.008, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: layout.sleeve * 0.03, x: 0, y: layout.sleeve * 0.015)
        .animation(.easeInOut(duration: 0.6), value: loadedArtworkKey)
        .position(layout.sleeveCenter)
        .accessibilityLabel(nowPlaying.now.track.map { "Album cover for \($0.album)" } ?? "Album cover")
    }

    // MARK: Record

    private func record(_ layout: SleeveLayout) -> some View {
        ZStack {
            if let discImage {
                TimelineView(.animation(minimumInterval: frameInterval, paused: !spinTimelineRunning)) { context in
                    Image(uiImage: discImage)
                        .resizable()
                        .frame(width: layout.disc, height: layout.disc)
                        .rotationEffect(.degrees(spin.angle(at: context.date)))
                }
                .transition(.opacity)
                .id(discRenderKey(layout))
            } else {
                Circle().fill(Color(white: 0.06))
            }
            // Light falls on the record from the room, so the sheen doesn't turn.
            Circle()
                .fill(AngularGradient(
                    colors: [.clear, .white.opacity(0.14), .clear, .clear, .white.opacity(0.10), .clear, .clear],
                    center: .center, angle: .degrees(-40)))
                .blendMode(.screen)
                .allowsHitTesting(false)

            if let bubble = platterBubble {
                TimeBubble(text: bubble)
                    .offset(y: -layout.disc * 0.28)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .frame(width: layout.disc, height: layout.disc)
        .animation(.easeInOut(duration: 0.5), value: discImage)
        .animation(.spring(response: 0.3, dampingFraction: 1), value: platterBubble == nil)
        .shadow(color: .black.opacity(0.4), radius: layout.disc * 0.035, x: layout.disc * 0.01, y: layout.disc * 0.02)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in platterChanged(value, layout: layout) }
                .onEnded { _ in platterEnded() }
        )
        .position(layout.discCenter)
        .accessibilityElement()
        .accessibilityLabel(nowPlaying.now.state == .playing ? "Record, playing" : "Record")
        .accessibilityHint("Double-tap to play or pause. Turn to move through the song.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { Task { await nowPlaying.perform(.toggle) } }
        .accessibilityAdjustableAction { direction in
            guard let position = displayedPosition(at: Date()) else { return }
            Task { await nowPlaying.seek(to: max(0, position + (direction == .increment ? 15 : -15))) }
        }
    }

    private var platterBubble: String? {
        guard let platter, abs(platter.turned) > 3,
              let duration = nowPlaying.now.track?.duration, duration > 0,
              let position = displayedPosition(at: Date())
        else { return nil }
        let delta = position - platter.startPosition
        return "\(delta >= 0 ? "+" : "−")\(Scrubber.format(abs(delta)))  ·  \(Scrubber.format(position))"
    }

    // MARK: Hand on the record

    struct PlatterDrag {
        var lastFingerAngle: Double
        /// Degrees turned by hand so far (clockwise positive).
        var turned: Double = 0
        var startPlatterAngle: Double
        var startPosition: TimeInterval
        var startTime = Date()
        var travel: CGFloat = 0
        var samples: [(time: Date, turned: Double)] = []
        var lastTick = 0
    }

    private func platterChanged(_ value: DragGesture.Value, layout: SleeveLayout) {
        let center = CGPoint(x: layout.disc / 2, y: layout.disc / 2)
        let dx = value.location.x - center.x, dy = value.location.y - center.y
        let finger = atan2(dy, dx) * 180 / .pi
        let now = Date()

        guard var drag = platter else {
            // Touch-down: the platter stops under the finger, right away.
            let current = spin.angle(at: now)
            spin.hold(angle: current, at: now)
            spinTimelineRunning = true
            platter = PlatterDrag(
                lastFingerAngle: finger,
                startPlatterAngle: current,
                startPosition: displayedPosition(at: now) ?? 0,
                samples: [(now, 0)]
            )
            return
        }

        var delta = finger - drag.lastFingerAngle
        if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
        // Near the spindle the angle swings wildly for tiny moves; ignore it there.
        if hypot(dx, dy) < layout.disc * 0.08 { delta = 0 }
        drag.turned += delta
        drag.lastFingerAngle = finger
        drag.travel = max(drag.travel, hypot(value.translation.width, value.translation.height))
        drag.samples.append((now, drag.turned))
        drag.samples.removeAll { now.timeIntervalSince($0.time) > 0.1 }
        spin.hold(angle: drag.startPlatterAngle + drag.turned, at: now)

        // A light tick every 5 s scrubbed, so you can feel your way through.
        let tick = Int((drag.turned / 360 * Self.secondsPerTurn / 5).rounded(.towardZero))
        if tick != drag.lastTick, nowPlaying.now.track?.duration != nil {
            drag.lastTick = tick
            Haptics.tick()
        }
        platter = drag
    }

    private func platterEnded() {
        guard let drag = platter else { return }
        platter = nil
        let now = Date()
        let angle = drag.startPlatterAngle + drag.turned
        let isTap = drag.travel < 10 && abs(drag.turned) < 4 && now.timeIntervalSince(drag.startTime) < 0.4

        // Release velocity (deg/s) from the last ~100 ms of movement.
        var velocity = 0.0
        if !isTap, let first = drag.samples.first, let last = drag.samples.last, last.time > first.time {
            velocity = (last.turned - first.turned) / last.time.timeIntervalSince(first.time)
        }
        let motor = spinTarget
        let ramp = spin.release(angle: angle, velocity: velocity, toward: motor, at: now)
        keepSpinTimelineRunning(for: ramp)

        if isTap {
            Task { await nowPlaying.perform(.toggle) }
            return
        }
        guard let duration = nowPlaying.now.track?.duration, duration > 0 else { return }
        // The fling keeps turning the record while it eases back to motor
        // speed; count that extra turn too, so sound follows the picture.
        let flick = (velocity - motor) * ramp / 2
        let seconds = (drag.turned + flick) / 360 * Self.secondsPerTurn
        let target = min(max(0, drag.startPosition + seconds), duration - 1)
        guard abs(seconds) > 0.75 else { return }
        commitSeek(to: target)
    }

    private func commitSeek(to target: TimeInterval) {
        pendingSeek = PendingSeek(position: target, at: Date(), expires: Date().addingTimeInterval(4))
        Task { await nowPlaying.seek(to: target) }
    }

    // MARK: Tonearm

    struct ArmDrag {
        /// Finger angle minus arm angle at pickup, so the arm doesn't jump to the finger.
        var grabOffset: Double
        var angle: Double
    }

    @ViewBuilder
    private func tonearm(_ layout: SleeveLayout, date: Date) -> some View {
        let (angle, lifted) = armPose(layout, date: date)
        let dragging = arm != nil
        ZStack {
            TonearmGraphic(layout: layout, angle: angle, lifted: lifted)
                .animation(dragging ? nil : .spring(response: 0.55, dampingFraction: 1), value: angle)
                .animation(.spring(response: 0.3, dampingFraction: 1), value: lifted)
            if dragging, let text = armBubble(layout, angle: angle) {
                let head = layout.needlePoint(angle: angle)
                TimeBubble(text: text)
                    .position(x: head.x - 10, y: head.y - layout.disc * 0.09)
                    .transition(.opacity)
            }
        }
        .contentShape(
            ArmShape(part: .tube, pivot: layout.pivot, length: layout.armLength, angle: angle)
                .stroke(style: StrokeStyle(lineWidth: max(44, layout.disc * 0.09), lineCap: .round))
        )
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.stage))
                .onChanged { value in armChanged(value, layout: layout, currentAngle: angle) }
                .onEnded { _ in armEnded(layout) }
        )
        .accessibilityHidden(true)
    }

    private func armPose(_ layout: SleeveLayout, date: Date) -> (Double, Bool) {
        if let arm { return (arm.angle, true) }
        let now = nowPlaying.now
        let outer = layout.outerGroove, inner = layout.innerGroove
        guard now.track != nil else {
            if idleSpinning && !armParked {
                // No player: slowly play through a built-in record (25 minutes a side).
                let p = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1500) / 1500
                return (layout.armAngle(toRadius: outer - (outer - inner) * p), false)
            }
            return (layout.restAngle, false)
        }
        if now.state == .stopped || armParked { return (layout.restAngle, false) }
        let progress = displayedProgress(at: date) ?? 0
        return (layout.armAngle(toRadius: outer - (outer - inner) * progress), now.state == .paused && platter == nil)
    }

    private func armChanged(_ value: DragGesture.Value, layout: SleeveLayout, currentAngle: Double) {
        let finger = atan2(value.location.y - layout.pivot.y, value.location.x - layout.pivot.x)
        guard var drag = arm else {
            arm = ArmDrag(grabOffset: finger - currentAngle, angle: currentAngle)
            Haptics.lift()
            return
        }
        // Past the rest or the run-out the arm resists instead of stopping dead.
        let lower = layout.restAngle - 0.05
        let upper = layout.armAngle(toRadius: layout.innerGroove) + 0.04
        drag.angle = rubberBand(finger - drag.grabOffset, lower: lower, upper: upper)
        arm = drag
    }

    private func armEnded(_ layout: SleeveLayout) {
        guard let drag = arm else { return }
        let radius = layout.needleRadius(angle: drag.angle)
        let onRecord = radius <= layout.outerGroove + layout.disc * 0.02
        let track = nowPlaying.now.track

        if !onRecord || track == nil {
            // Parked on the rest: lifting the needle stops the music.
            armParked = true
            arm = nil
            Haptics.drop(intensity: 0.5)
            if nowPlaying.now.state == .playing { Task { await nowPlaying.perform(.pause) } }
            return
        }

        let progress = layout.progress(atRadius: radius)
        armParked = false
        if let duration = track?.duration, duration > 0 {
            let target = min(max(0, progress * duration), duration - 1)
            pendingSeek = PendingSeek(position: target, at: Date(), expires: Date().addingTimeInterval(4))
            arm = nil
            Haptics.drop(intensity: 1)
            let wasPlaying = nowPlaying.now.state == .playing
            Task {
                await nowPlaying.seek(to: target)
                if !wasPlaying { await nowPlaying.perform(.play) }
            }
        } else {
            arm = nil
            Haptics.drop(intensity: 1)
            if nowPlaying.now.state != .playing { Task { await nowPlaying.perform(.play) } }
        }
    }

    private func armBubble(_ layout: SleeveLayout, angle: Double) -> String? {
        let radius = layout.needleRadius(angle: angle)
        guard radius <= layout.outerGroove + layout.disc * 0.02 else { return "Rest · pause" }
        guard let duration = nowPlaying.now.track?.duration, duration > 0 else { return nil }
        return Scrubber.format(layout.progress(atRadius: radius) * duration)
    }

    private func rubberBand(_ value: Double, lower: Double, upper: Double) -> Double {
        let dimension = 0.35, constant = 0.55
        func band(_ overshoot: Double) -> Double { overshoot * dimension * constant / (dimension + constant * overshoot) }
        if value < lower { return lower - band(lower - value) }
        if value > upper { return upper + band(value - upper) }
        return value
    }

    // MARK: Position

    struct PendingSeek {
        var position: TimeInterval
        var at: Date
        var expires: Date

        func position(at date: Date, playing: Bool) -> TimeInterval {
            position + (playing ? max(0, date.timeIntervalSince(at)) : 0)
        }
    }

    /// The song position on screen: under the hand, just sent, or as played.
    private func displayedPosition(at date: Date) -> TimeInterval? {
        guard let duration = nowPlaying.now.track?.duration, duration > 0 else { return nil }
        if let platter {
            return min(max(0, platter.startPosition + platter.turned / 360 * Self.secondsPerTurn), duration)
        }
        if let pendingSeek, date < pendingSeek.expires {
            return min(duration, pendingSeek.position(at: date, playing: nowPlaying.now.state == .playing))
        }
        return min(duration, nowPlaying.now.position(at: date))
    }

    private func displayedProgress(at date: Date) -> Double? {
        guard let duration = nowPlaying.now.track?.duration, duration > 0, let position = displayedPosition(at: date) else { return nil }
        return min(1, max(0, position / duration))
    }

    // MARK: Caption

    private var caption: some View {
        let track = nowPlaying.now.track
        let light = prefs.sleeveBackground == .light
        return VStack(alignment: .leading, spacing: 3) {
            Text(track?.title ?? "Vinyl")
                .font(.system(.title3, design: .serif).weight(.semibold))
            Text(track.map { [$0.artist, $0.album].filter { !$0.isEmpty }.joined(separator: " — ") }
                 ?? (nowPlaying.hasAnySource ? "Play something in Spotify or Apple Music" : "Connect a player in Settings"))
                .font(.subheadline)
                .opacity(0.75)
        }
        .lineLimit(1)
        .foregroundStyle(light ? Color.black : Color.white)
        .shadow(color: light ? .clear : .black.opacity(0.35), radius: 4)
        .animation(.easeInOut(duration: 0.4), value: track?.id)
    }

    // MARK: Spin

    private var idleSpinning: Bool { nowPlaying.now.track == nil && prefs.spinWhenIdle }

    /// Degrees per second the motor drives the platter at.
    private var spinTarget: Double {
        if reduceMotion { return 0 }
        return nowPlaying.now.state == .playing || idleSpinning ? SpinModel.thirtyThree : 0
    }

    private var frameInterval: Double {
        let saver = prefs.energy == .saver || (prefs.energy == .automatic && ProcessInfo.processInfo.isLowPowerModeEnabled)
        return saver ? 1.0 / 30 : 1.0 / 60
    }

    private func updateSpin() {
        // A hand on the record wins over the motor.
        guard platter == nil else { return }
        let target = spinTarget
        spin.setSpeed(target)
        keepSpinTimelineRunning(for: SpinModel.defaultRamp)
    }

    /// Draws frames while the platter moves, then stops the timeline entirely.
    private func keepSpinTimelineRunning(for seconds: Double) {
        spinTimelineRunning = true
        guard spinTarget == 0 else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64((seconds + 0.15) * 1_000_000_000))
            if spinTarget == 0 && platter == nil { spinTimelineRunning = false }
        }
    }

    // MARK: Artwork + disc rendering

    private var artworkKey: String {
        nowPlaying.artworkPending ? "pending" : (nowPlaying.artworkFile ?? "none")
    }

    private func loadArtwork() async {
        // While new artwork loads, keep showing the previous cover.
        guard !nowPlaying.artworkPending else { return }
        let key = artworkKey
        guard let file = nowPlaying.artworkFile, nowPlaying.now.track != nil else {
            artwork = nil
            palette = .neutral
            loadedArtworkKey = key
            return
        }
        let url = ArtworkStore.shared.url(forFile: file)
        let loaded = await Task.detached(priority: .userInitiated) { () -> (UIImage?, AlbumPalette?) in
            (UIImage(contentsOfFile: url.path), AlbumPalette.extract(fromFile: url))
        }.value
        guard !Task.isCancelled else { return }
        artwork = loaded.0
        palette = loaded.1 ?? .neutral
        loadedArtworkKey = key
    }

    private var albumKey: String { nowPlaying.now.track?.albumKey ?? "idle" }

    private var resolvedStyle: VinylStyle {
        prefs.vinylStyle.resolved(for: palette, albumKey: albumKey)
    }

    private func discRenderKey(_ layout: SleeveLayout) -> String {
        let track = nowPlaying.now.track
        return [
            "\(Int(layout.disc / 8))",
            prefs.labelStyle.rawValue,
            resolvedStyle.rawValue,
            loadedArtworkKey,
            track?.title ?? "",
            track?.artist ?? "",
        ].joined(separator: "|")
    }

    private func renderDisc(diameter: CGFloat) {
        guard diameter > 10 else { return }
        let track = nowPlaying.now.track
        let face = RecordFace(
            diameter: diameter,
            style: resolvedStyle,
            palette: palette,
            artwork: artwork,
            labelStyle: prefs.labelStyle,
            title: track?.title ?? "Vinyl",
            artist: track?.artist ?? (nowPlaying.hasAnySource ? "Side A" : "Connect a player"),
            seed: { var random = SeededRandom(string: albumKey); return random.next() }()
        )
        let renderer = ImageRenderer(content: face)
        renderer.scale = displayScale
        renderer.isOpaque = false
        // Rendered once per album; spinning just rotates this image.
        discImage = renderer.uiImage
    }

    private static let idleCover: UIImage = {
        if let url = Bundle.main.url(forResource: "hiroshige_ryogoku", withExtension: "jpg", subdirectory: "Renderer/art"),
           let image = UIImage(contentsOfFile: url.path) {
            return image
        }
        return UIImage()
    }()
}

// MARK: - Time bubble

/// A small floating readout next to the finger while scrubbing.
struct TimeBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .environment(\.colorScheme, .dark)
            .foregroundStyle(.white)
            .allowsHitTesting(false)
    }
}

// MARK: - Haptics

/// Feedback on the frame the physical event happens: picking up the arm,
/// the needle landing, the record ticking past each 5 seconds.
/// (iPads have no Taptic Engine, so these are silent there.)
@MainActor
enum Haptics {
    private static let selection = UISelectionFeedbackGenerator()

    static func lift() { UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.6) }
    static func drop(intensity: CGFloat) { UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: intensity) }
    static func tick() { selection.selectionChanged() }
}

// MARK: - Layout

/// Where everything sits. Landscape: sleeve left, record overlapping to the
/// right. Portrait: sleeve on top, record below. The tonearm hangs off the
/// record's upper right in both.
struct SleeveLayout {
    let sleeve: CGFloat
    let disc: CGFloat
    let sleeveCenter: CGPoint
    let discCenter: CGPoint
    let pivot: CGPoint
    let armLength: CGFloat

    init(size: CGSize, captionSpace: CGFloat) {
        let w = size.width
        let h = max(1, size.height - captionSpace)
        if h <= w * 1.1 {
            // Sleeve + two-thirds of the record + room for the arm ≈ 1.84 sleeves wide.
            let s = min(h * 0.8, w * 0.92 / 1.84)
            let left = (w - 1.84 * s) / 2
            sleeve = s
            sleeveCenter = CGPoint(x: left + s / 2, y: h / 2)
            discCenter = CGPoint(x: left + 1.17 * s, y: h / 2)
        } else {
            let s = min(w * 0.70, h * 0.9 / 1.67)
            let top = (h - 1.67 * s) / 2
            let x = w / 2 - 0.06 * s
            sleeve = s
            sleeveCenter = CGPoint(x: x, y: top + s / 2)
            discCenter = CGPoint(x: x, y: top + 1.17 * s)
        }
        disc = sleeve
        pivot = CGPoint(x: discCenter.x + 0.56 * disc, y: discCenter.y - 0.38 * disc)
        armLength = 0.66 * disc
    }

    var outerGroove: CGFloat { disc * 0.462 }
    var innerGroove: CGFloat { disc * 0.205 }

    /// Parked on its rest, just off the record.
    var restAngle: Double { 88 * .pi / 180 }

    /// The arm angle (radians, screen coordinates) that puts the stylus at
    /// `radius` from the spindle: where the circle the stylus can reach
    /// crosses the groove.
    func armAngle(toRadius radius: CGFloat) -> Double {
        let dx = pivot.x - discCenter.x, dy = pivot.y - discCenter.y
        let d = sqrt(dx * dx + dy * dy)
        let a = (radius * radius - armLength * armLength + d * d) / (2 * d)
        let hh = sqrt(max(0, radius * radius - a * a))
        let ux = dx / d, uy = dy / d
        // The crossing on the lower side, where the arm hangs.
        let nx = discCenter.x + a * ux - hh * uy
        let ny = discCenter.y + a * uy + hh * ux
        return atan2(ny - pivot.y, nx - pivot.x)
    }

    func needlePoint(angle: Double) -> CGPoint {
        CGPoint(x: pivot.x + armLength * CGFloat(cos(angle)), y: pivot.y + armLength * CGFloat(sin(angle)))
    }

    func needleRadius(angle: Double) -> CGFloat {
        let p = needlePoint(angle: angle)
        return hypot(p.x - discCenter.x, p.y - discCenter.y)
    }

    /// 0 at the outer groove, 1 at the run-out.
    func progress(atRadius radius: CGFloat) -> Double {
        min(1, max(0, (outerGroove - radius) / (outerGroove - innerGroove)))
    }
}

// MARK: - Spin

/// Platter rotation: motor spin-up/down, a hand holding it, and a fling that
/// eases back to motor speed from the release velocity (no seam between the
/// hand and the motor).
struct SpinModel {
    static let thirtyThree: Double = 200 // 33⅓ rpm in degrees per second
    static let defaultRamp: Double = 0.9

    private var baseAngle: Double = 0
    private var baseDate = Date()
    private var fromSpeed: Double = 0
    private var toSpeed: Double = 0
    private var ramp: Double = SpinModel.defaultRamp

    func angle(at date: Date) -> Double {
        let t = max(0, date.timeIntervalSince(baseDate))
        let r = ramp
        if t < r { return baseAngle + fromSpeed * t + (toSpeed - fromSpeed) * t * t / (2 * r) }
        return baseAngle + fromSpeed * r + (toSpeed - fromSpeed) * r / 2 + toSpeed * (t - r)
    }

    func speed(at date: Date) -> Double {
        let t = max(0, date.timeIntervalSince(baseDate))
        return t < ramp ? fromSpeed + (toSpeed - fromSpeed) * t / ramp : toSpeed
    }

    /// The motor changes speed (play/pause).
    mutating func setSpeed(_ speed: Double, at date: Date = Date()) {
        guard speed != toSpeed else { return }
        baseAngle = angle(at: date).truncatingRemainder(dividingBy: 360)
        fromSpeed = self.speed(at: date)
        toSpeed = speed
        baseDate = date
        ramp = Self.defaultRamp
    }

    /// A hand holds the record at `angle`.
    mutating func hold(angle: Double, at date: Date = Date()) {
        baseAngle = angle
        fromSpeed = 0
        toSpeed = 0
        baseDate = date
        ramp = 0.001
    }

    /// The hand lets go at `velocity` (deg/s); friction and the motor bring it
    /// to `motor`. Returns how long that takes.
    @discardableResult
    mutating func release(angle: Double, velocity: Double, toward motor: Double, at date: Date = Date()) -> Double {
        baseAngle = angle.truncatingRemainder(dividingBy: 360)
        fromSpeed = velocity
        toSpeed = motor
        baseDate = date
        ramp = min(1.6, max(0.35, abs(velocity - motor) / 700))
        return ramp
    }
}

// MARK: - Tonearm

/// The arm, its bearing and counterweight. Lifted = paused or in the hand
/// (a longer, softer shadow).
struct TonearmGraphic: View {
    let layout: SleeveLayout
    let angle: Double
    let lifted: Bool

    var body: some View {
        ZStack {
            // Bearing base.
            Circle()
                .fill(RadialGradient(colors: [Color(white: 0.96), Color(white: 0.72)],
                                     center: .topLeading, startRadius: 0, endRadius: layout.disc * 0.1))
                .frame(width: layout.disc * 0.15, height: layout.disc * 0.15)
                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                .position(layout.pivot)
            arm
                .shadow(color: .black.opacity(lifted ? 0.25 : 0.38),
                        radius: lifted ? 9 : 2.5,
                        x: lifted ? 9 : 2, y: lifted ? 13 : 3)
            Circle()
                .fill(RadialGradient(colors: [.white, Color(white: 0.78)],
                                     center: .topLeading, startRadius: 0, endRadius: layout.disc * 0.04))
                .frame(width: layout.disc * 0.06, height: layout.disc * 0.06)
                .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                .position(layout.pivot)
        }
    }

    private var arm: some View {
        // Slim and white, like a modern deck.
        let finish = LinearGradient(colors: [.white, Color(white: 0.8)], startPoint: .top, endPoint: .bottom)
        return ZStack {
            ArmShape(part: .tube, pivot: layout.pivot, length: layout.armLength, angle: angle)
                .stroke(finish, style: StrokeStyle(lineWidth: layout.disc * 0.012, lineCap: .round))
            ArmShape(part: .counterweight, pivot: layout.pivot, length: layout.armLength, angle: angle)
                .fill(Color(white: 0.22))
            ArmShape(part: .headshell, pivot: layout.pivot, length: layout.armLength, angle: angle)
                .fill(Color(white: 0.97))
        }
    }
}

/// One part of the tonearm, drawn along the arm's axis and rotated about the
/// pivot. Animatable, so moves glide instead of jumping.
struct ArmShape: Shape {
    enum Part { case tube, counterweight, headshell }
    let part: Part
    let pivot: CGPoint
    let length: CGFloat
    var angle: Double

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let L = length
        switch part {
        case .tube:
            path.move(to: CGPoint(x: -0.12 * L, y: 0))
            path.addLine(to: CGPoint(x: 0.6 * L, y: 0))
            // A gentle S-bend toward the headshell, like a real arm.
            path.addQuadCurve(to: CGPoint(x: 0.9 * L, y: -0.035 * L), control: CGPoint(x: 0.78 * L, y: 0.03 * L))
        case .counterweight:
            path.addRoundedRect(in: CGRect(x: -0.3 * L, y: -0.05 * L, width: 0.15 * L, height: 0.1 * L),
                                cornerSize: CGSize(width: 0.02 * L, height: 0.02 * L))
        case .headshell:
            let shell = CGRect(x: 0.88 * L, y: -0.07 * L, width: 0.16 * L, height: 0.075 * L)
            path.addRoundedRect(in: shell, cornerSize: CGSize(width: 0.012 * L, height: 0.012 * L))
        }
        return path.applying(CGAffineTransform(translationX: pivot.x, y: pivot.y).rotated(by: angle))
    }
}
