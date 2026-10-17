import SwiftUI
import UIKit

/// The record, rendered to an image once per album; spinning just rotates it.
/// Coloured pressings are translucent, so the room shows through the vinyl.
struct RecordFace: View {
    let diameter: CGFloat
    /// Already resolved (never `.automatic`).
    let style: VinylStyle
    let palette: AlbumPalette
    let artwork: UIImage?
    let labelStyle: LabelStyle
    let title: String
    let artist: String
    /// Same album → same splatter, every time.
    let seed: UInt64

    var body: some View {
        let labelSize = diameter * 0.36
        ZStack {
            disc
            Canvas { ctx, size in
                let radius = size.width / 2
                let center = CGPoint(x: radius, y: radius)
                // A copy, so the pattern's clip doesn't trim the grooves and rim.
                var patternContext = ctx
                drawPattern(in: &patternContext, center: center, radius: radius)
                drawGrooves(in: &ctx, center: center, radius: radius)
            }
            label(size: labelSize)
            // Spindle hole.
            Circle()
                .fill(Color(white: 0.86))
                .frame(width: diameter * 0.022, height: diameter * 0.022)
                .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 0.5))
        }
        .frame(width: diameter, height: diameter)
        .compositingGroup()
    }

    // MARK: Vinyl

    private var isClassic: Bool { style == .classic }

    @ViewBuilder
    private var disc: some View {
        if isClassic {
            Circle()
                .fill(RadialGradient(colors: [Color(white: 0.11), Color(white: 0.035)],
                                     center: .center, startRadius: 0, endRadius: diameter / 2))
        } else {
            let vinyl = palette.vinyl
            ZStack {
                // Translucent body: the room shows through.
                Circle()
                    .fill(RadialGradient(
                        colors: [vinyl.color.opacity(0.5), vinyl.color.opacity(0.62), vinyl.adjusted(saturation: { $0 }, brightness: { $0 * 0.8 }).color.opacity(0.78)],
                        center: .center, startRadius: diameter * 0.18, endRadius: diameter / 2))
                // Thicker, less clear dead wax around the label.
                Circle()
                    .fill(vinyl.color.opacity(0.35))
                    .frame(width: diameter * 0.42, height: diameter * 0.42)
            }
        }
    }

    private func ring(_ center: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
    }

    private func drawGrooves(in ctx: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
        let light = isClassic ? 0.06 : 0.10
        let dark = isClassic ? 0.0 : 0.08
        var r = radius * 0.965
        var i = 0
        while r > radius * 0.39 {
            let strong = i % 6 == 0
            ctx.stroke(ring(center, r), with: .color(.white.opacity(strong ? light * 2 : light)), lineWidth: max(0.5, radius * 0.0022))
            if dark > 0 {
                ctx.stroke(ring(center, r - radius * 0.004), with: .color(.black.opacity(dark)), lineWidth: max(0.5, radius * 0.002))
            }
            r -= radius * (i % 14 == 13 ? 0.026 : 0.0095)
            i += 1
        }
        ctx.stroke(ring(center, radius * 0.375), with: .color(.white.opacity(0.08)), lineWidth: radius * 0.004)
        // Bevelled edge catching the light.
        ctx.stroke(ring(center, radius * 0.993), with: .color(.white.opacity(isClassic ? 0.10 : 0.28)), lineWidth: radius * 0.012)
    }

    private func drawPattern(in ctx: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
        guard style == .splatter || style == .burst else { return }
        var rng = SeededRandom(seed: seed)
        // Keep the pattern on the playing surface, off the label.
        var annulus = ring(center, radius * 0.985)
        annulus.addPath(ring(center, radius * 0.385))
        ctx.clip(to: annulus, style: FillStyle(eoFill: true))

        let accent = palette.accent
        let deep = palette.vinyl.adjusted(saturation: { $0 }, brightness: { $0 * 0.45 })
        if style == .splatter {
            for _ in 0..<280 {
                let roll = Double.random(in: 0...1, using: &rng)
                let tint: PaletteColor = roll < 0.55 ? accent : (roll < 0.85 ? deep : .white)
                // Area-uniform position across the surface.
                let rr = sqrt(Double.random(in: 0.15...0.97, using: &rng)) * radius
                let theta = Double.random(in: 0...(2 * .pi), using: &rng)
                let p = CGPoint(x: center.x + rr * cos(theta), y: center.y + rr * sin(theta))
                // Mostly fine specks, the odd big drop.
                let size = radius * (Double.random(in: 0...1, using: &rng) < 0.06
                                     ? Double.random(in: 0.025...0.05, using: &rng)
                                     : Double.random(in: 0.003...0.016, using: &rng))
                let alpha = Double.random(in: 0.65...0.95, using: &rng)
                // A main drop with a couple of satellites reads as splashed paint.
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - size, y: p.y - size * 0.85, width: size * 2, height: size * 1.7)),
                         with: .color(tint.color.opacity(alpha)))
                for _ in 0..<Int.random(in: 0...2, using: &rng) {
                    let d = size * Double.random(in: 1.2...2.4, using: &rng)
                    let a = Double.random(in: 0...(2 * .pi), using: &rng)
                    let s = size * Double.random(in: 0.2...0.45, using: &rng)
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x + d * cos(a) - s, y: p.y + d * sin(a) - s, width: s * 2, height: s * 2)),
                             with: .color(tint.color.opacity(alpha)))
                }
            }
        } else {
            // Starburst: streaks flaring out from the label.
            ctx.fill(ring(center, radius * 0.62),
                     with: .radialGradient(Gradient(colors: [accent.color.opacity(0.55), accent.color.opacity(0)]),
                                           center: center, startRadius: radius * 0.38, endRadius: radius * 0.62))
            for _ in 0..<150 {
                let theta = Double.random(in: 0...(2 * .pi), using: &rng)
                let inner = radius * 0.38
                let outer = radius * Double.random(in: 0.55...1.0, using: &rng)
                let width = Double.random(in: 0.004...0.02, using: &rng)
                var streak = Path()
                streak.move(to: CGPoint(x: center.x + inner * cos(theta - width), y: center.y + inner * sin(theta - width)))
                streak.addLine(to: CGPoint(x: center.x + outer * cos(theta), y: center.y + outer * sin(theta)))
                streak.addLine(to: CGPoint(x: center.x + inner * cos(theta + width), y: center.y + inner * sin(theta + width)))
                streak.closeSubpath()
                let tint = Double.random(in: 0...1, using: &rng) < 0.8 ? accent : .white
                ctx.fill(streak, with: .color(tint.color.opacity(Double.random(in: 0.35...0.85, using: &rng))))
            }
        }
    }

    // MARK: Label

    @ViewBuilder
    private func label(size: CGFloat) -> some View {
        if labelStyle == .picture, let artwork {
            Image(uiImage: artwork)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            let ink = palette.labelInk.color
            ZStack {
                Circle().fill(palette.label.color)
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

/// SplitMix64: a tiny deterministic generator so patterns repeat per album.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    init(string: String) {
        state = string.utf8.reduce(0xcbf29ce484222325) { ($0 ^ UInt64($1)) &* 0x100000001b3 }
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
