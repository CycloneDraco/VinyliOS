import SwiftUI
import UIKit

/// The native scene: the album sleeve with its record slid half out, a
/// tonearm that tracks through the song, and the record spinning at 33⅓.
/// Drawn with SwiftUI (no WebGL), so it's light enough to leave on all day.
struct SleeveSceneView: View {
    @EnvironmentObject private var nowPlaying: NowPlayingService
    @EnvironmentObject private var prefs: Preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    @State private var artwork: UIImage?
    /// Which artwork `artwork` and the label colour currently reflect.
    @State private var loadedArtworkKey = ""
    @State private var labelColor = Color(red: 0.93, green: 0.90, blue: 0.84)
    @State private var labelInk = Color.black
    @State private var discImage: UIImage?
    @State private var spin = SpinModel()
    @State private var spinTimelineRunning = false

    var body: some View {
        GeometryReader { geo in
            let layout = SleeveLayout(size: geo.size, captionSpace: prefs.showTrackInfo ? min(76, geo.size.height * 0.13) : 0)
            ZStack(alignment: .topLeading) {
                background
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()

                sleeve(layout)
                record(layout)
                TonearmView(layout: layout, nowPlaying: nowPlaying, idleSpin: idleSpinning)

                if prefs.showTrackInfo {
                    caption
                        .frame(width: geo.size.width - 56, alignment: .leading)
                        .position(x: geo.size.width / 2, y: geo.size.height - 44)
                }
            }
            .task(id: discRenderKey(layout)) { renderDisc(diameter: layout.disc) }
        }
        .ignoresSafeArea()
        .task(id: artworkKey) { await loadArtwork() }
        .onAppear { updateSpin() }
        .onChange(of: spinTarget) { _, _ in updateSpin() }
    }

    // MARK: Pieces

    @ViewBuilder
    private var background: some View {
        switch prefs.sleeveBackground {
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

    private func sleeve(_ layout: SleeveLayout) -> some View {
        ZStack {
            Image(uiImage: artwork ?? Self.idleCover)
                .resizable()
                .scaledToFill()
                .frame(width: layout.sleeve, height: layout.sleeve)
                .clipped()
                .transition(.opacity)
                .id(loadedArtworkKey)
            // Faint gloss and edge wear, like printed card.
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
                    colors: [.clear, .white.opacity(0.13), .clear, .clear, .white.opacity(0.09), .clear, .clear],
                    center: .center, angle: .degrees(-40)))
                .blendMode(.screen)
                .allowsHitTesting(false)
        }
        .frame(width: layout.disc, height: layout.disc)
        .animation(.easeInOut(duration: 0.5), value: discImage)
        .shadow(color: .black.opacity(0.45), radius: layout.disc * 0.035, x: layout.disc * 0.01, y: layout.disc * 0.02)
        .contentShape(Circle())
        .onTapGesture {
            Task { await nowPlaying.perform(.toggle) }
        }
        .position(layout.discCenter)
        .accessibilityElement()
        .accessibilityLabel(nowPlaying.now.state == .playing ? "Record, playing. Tap to pause." : "Record. Tap to play.")
        .accessibilityAddTraits(.isButton)
    }

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

    /// Degrees per second the platter should reach.
    private var spinTarget: Double {
        if reduceMotion { return 0 }
        return nowPlaying.now.state == .playing || idleSpinning ? SpinModel.thirtyThree : 0
    }

    private var frameInterval: Double {
        let saver = prefs.energy == .saver || (prefs.energy == .automatic && ProcessInfo.processInfo.isLowPowerModeEnabled)
        return saver ? 1.0 / 30 : 1.0 / 60
    }

    private func updateSpin() {
        let target = spinTarget
        spin.setSpeed(target)
        if target > 0 {
            spinTimelineRunning = true
        } else {
            // Keep drawing through the spin-down, then stop the timeline entirely.
            spinTimelineRunning = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64((SpinModel.ramp + 0.15) * 1_000_000_000))
                if spinTarget == 0 { spinTimelineRunning = false }
            }
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
            setLabelColor(nil)
            loadedArtworkKey = key
            return
        }
        let url = ArtworkStore.shared.url(forFile: file)
        let loaded = await Task.detached(priority: .userInitiated) { () -> (UIImage?, (red: Double, green: Double, blue: Double)?) in
            (UIImage(contentsOfFile: url.path), ArtworkStore.averageColor(ofFile: url))
        }.value
        guard !Task.isCancelled else { return }
        artwork = loaded.0
        setLabelColor(loaded.1)
        loadedArtworkKey = key
    }

    private func setLabelColor(_ average: (red: Double, green: Double, blue: Double)?) {
        guard let average else {
            labelColor = Color(red: 0.93, green: 0.90, blue: 0.84)
            labelInk = .black
            return
        }
        // A soft, printed-paper version of the cover's colour.
        let mix = 0.5
        let r = average.red + (1 - average.red) * mix
        let g = average.green + (1 - average.green) * mix
        let b = average.blue + (1 - average.blue) * mix
        labelColor = Color(red: r, green: g, blue: b)
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        labelInk = luminance > 0.6 ? Color(white: 0.12) : .white
    }

    private func discRenderKey(_ layout: SleeveLayout) -> String {
        let track = nowPlaying.now.track
        return [
            "\(Int(layout.disc / 8))",
            prefs.labelStyle.rawValue,
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
            artwork: artwork,
            style: prefs.labelStyle,
            labelColor: labelColor,
            ink: labelInk,
            title: track?.title ?? "Vinyl",
            artist: track?.artist ?? (nowPlaying.hasAnySource ? "Side A" : "Connect a player")
        )
        let renderer = ImageRenderer(content: face)
        renderer.scale = displayScale
        // Rendered once per track; spinning just rotates this image.
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

    /// Parked on its rest, just off the record.
    var restAngle: Double { 88 * .pi / 180 }
}

// MARK: - Spin

/// Platter rotation with a short spin-up and spin-down.
struct SpinModel {
    static let thirtyThree: Double = 200 // 33⅓ rpm in degrees per second
    static let ramp: Double = 0.9

    private var baseAngle: Double = 0
    private var baseDate = Date()
    private var fromSpeed: Double = 0
    private var toSpeed: Double = 0

    func angle(at date: Date) -> Double {
        let t = max(0, date.timeIntervalSince(baseDate))
        let r = Self.ramp
        if t < r { return baseAngle + fromSpeed * t + (toSpeed - fromSpeed) * t * t / (2 * r) }
        return baseAngle + fromSpeed * r + (toSpeed - fromSpeed) * r / 2 + toSpeed * (t - r)
    }

    func speed(at date: Date) -> Double {
        let t = max(0, date.timeIntervalSince(baseDate))
        return t < Self.ramp ? fromSpeed + (toSpeed - fromSpeed) * t / Self.ramp : toSpeed
    }

    mutating func setSpeed(_ speed: Double, at date: Date = Date()) {
        guard speed != toSpeed else { return }
        baseAngle = angle(at: date).truncatingRemainder(dividingBy: 360)
        fromSpeed = self.speed(at: date)
        toSpeed = speed
        baseDate = date
    }
}

// MARK: - Record face

/// The record itself, rendered to an image once per track.
struct RecordFace: View {
    let diameter: CGFloat
    let artwork: UIImage?
    let style: LabelStyle
    let labelColor: Color
    let ink: Color
    let title: String
    let artist: String

    var body: some View {
        let labelSize = diameter * 0.36
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color(white: 0.11), Color(white: 0.035)],
                                     center: .center, startRadius: 0, endRadius: diameter / 2))
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = size.width / 2
                func ring(_ r: CGFloat) -> Path {
                    Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                }
                // Grooves, with a wider gap between "tracks".
                var r = radius * 0.965
                var i = 0
                while r > radius * 0.39 {
                    let alpha = i % 6 == 0 ? 0.12 : 0.06
                    ctx.stroke(ring(r), with: .color(.white.opacity(alpha)), lineWidth: max(0.5, radius * 0.0022))
                    r -= radius * (i % 14 == 13 ? 0.026 : 0.0095)
                    i += 1
                }
                // Lead-out and rim.
                ctx.stroke(ring(radius * 0.375), with: .color(.white.opacity(0.07)), lineWidth: radius * 0.004)
                ctx.stroke(ring(radius * 0.993), with: .color(.white.opacity(0.10)), lineWidth: radius * 0.012)
            }
            label(size: labelSize)
            Circle()
                .fill(Color(white: 0.78))
                .frame(width: diameter * 0.022, height: diameter * 0.022)
                .overlay(Circle().stroke(Color.black.opacity(0.4), lineWidth: 0.5))
        }
        .frame(width: diameter, height: diameter)
    }

    @ViewBuilder
    private func label(size: CGFloat) -> some View {
        if style == .picture, let artwork {
            Image(uiImage: artwork)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            ZStack {
                Circle().fill(labelColor)
                Circle().stroke(ink.opacity(0.18), lineWidth: size * 0.006).padding(size * 0.05)
                VStack(spacing: 0) {
                    Text(title)
                        .font(.system(size: size * 0.085, weight: .semibold, design: .serif))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                        .frame(width: size * 0.66, height: size * 0.24, alignment: .bottom)
                    Spacer().frame(height: size * 0.16)
                    Text(artist)
                        .font(.system(size: size * 0.062, weight: .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(width: size * 0.62)
                    Text("33⅓ RPM")
                        .font(.system(size: size * 0.04, weight: .medium))
                        .tracking(size * 0.004)
                        .opacity(0.6)
                        .padding(.top, size * 0.04)
                }
                .foregroundStyle(ink)
                .offset(y: size * 0.01)
            }
            .frame(width: size, height: size)
        }
    }
}

// MARK: - Tonearm

/// Tracks the song: outer groove at 0:00, run-out at the end; parked when
/// stopped, lifted (bigger shadow) when paused.
struct TonearmView: View {
    let layout: SleeveLayout
    @ObservedObject var nowPlaying: NowPlayingService
    let idleSpin: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let (angle, lifted) = pose(at: context.date)
            ZStack {
                // Bearing base.
                Circle()
                    .fill(RadialGradient(colors: [Color(white: 0.55), Color(white: 0.22)],
                                         center: .topLeading, startRadius: 0, endRadius: layout.disc * 0.1))
                    .frame(width: layout.disc * 0.15, height: layout.disc * 0.15)
                    .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                    .position(layout.pivot)
                arm(angle: angle)
                    .shadow(color: .black.opacity(lifted ? 0.28 : 0.4),
                            radius: lifted ? 7 : 2.5,
                            x: lifted ? 7 : 2, y: lifted ? 10 : 3)
                    .animation(.easeInOut(duration: 1.0), value: angle)
                    .animation(.easeInOut(duration: 0.5), value: lifted)
                Circle()
                    .fill(RadialGradient(colors: [.white, Color(white: 0.6)],
                                         center: .topLeading, startRadius: 0, endRadius: layout.disc * 0.04))
                    .frame(width: layout.disc * 0.06, height: layout.disc * 0.06)
                    .position(layout.pivot)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func arm(angle: Double) -> some View {
        let silver = LinearGradient(colors: [Color(white: 0.95), Color(white: 0.62)], startPoint: .top, endPoint: .bottom)
        return ZStack {
            ArmShape(part: .tube, pivot: layout.pivot, length: layout.armLength, angle: angle)
                .stroke(silver, style: StrokeStyle(lineWidth: layout.disc * 0.013, lineCap: .round))
            ArmShape(part: .counterweight, pivot: layout.pivot, length: layout.armLength, angle: angle)
                .fill(Color(white: 0.16))
            ArmShape(part: .headshell, pivot: layout.pivot, length: layout.armLength, angle: angle)
                .fill(Color(white: 0.9))
        }
    }

    private func pose(at date: Date) -> (Double, Bool) {
        let now = nowPlaying.now
        let outer = layout.disc * 0.462
        let inner = layout.disc * 0.205
        guard let track = now.track else {
            if idleSpin {
                // No player: slowly play through a built-in record (25 minutes a side).
                let p = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1500) / 1500
                return (layout.armAngle(toRadius: outer - (outer - inner) * p), false)
            }
            return (layout.restAngle, false)
        }
        if now.state == .stopped { return (layout.restAngle, false) }
        var progress = 0.0
        if let duration = track.duration, duration > 0 {
            progress = min(1, max(0, now.position(at: date) / duration))
        }
        let angle = layout.armAngle(toRadius: outer - (outer - inner) * progress)
        return (angle, now.state == .paused)
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
