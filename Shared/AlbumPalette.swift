import ImageIO
import SwiftUI

/// An sRGB colour with the bits palette maths needs.
struct PaletteColor: Equatable {
    var red: Double
    var green: Double
    var blue: Double

    var color: Color { Color(red: red, green: green, blue: blue) }

    var luminance: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }

    var hsb: (hue: Double, saturation: Double, brightness: Double) {
        let maxV = max(red, green, blue), minV = min(red, green, blue)
        let delta = maxV - minV
        var hue = 0.0
        if delta > 0 {
            if maxV == red { hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6) }
            else if maxV == green { hue = (blue - red) / delta + 2 }
            else { hue = (red - green) / delta + 4 }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        return (hue, maxV == 0 ? 0 : delta / maxV, maxV)
    }

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(hue: Double, saturation: Double, brightness: Double) {
        let h = (hue - floor(hue)) * 6
        let c = brightness * saturation
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = brightness - c
        let (r, g, b): (Double, Double, Double)
        switch Int(h) {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        self.init(red: r + m, green: g + m, blue: b + m)
    }

    /// Same hue, adjusted saturation and brightness.
    func adjusted(saturation: (Double) -> Double, brightness: (Double) -> Double) -> PaletteColor {
        let (h, s, b) = hsb
        return PaletteColor(hue: h, saturation: min(1, max(0, saturation(s))), brightness: min(1, max(0, brightness(b))))
    }

    func mixed(with other: PaletteColor, _ amount: Double) -> PaletteColor {
        PaletteColor(red: red + (other.red - red) * amount,
                     green: green + (other.green - green) * amount,
                     blue: blue + (other.blue - blue) * amount)
    }

    static let white = PaletteColor(red: 1, green: 1, blue: 1)
    static let black = PaletteColor(red: 0, green: 0, blue: 0)
}

/// The colours a cover is built from: what the record, label and room are
/// tinted with so every album gets its own pressing.
struct AlbumPalette: Equatable {
    /// The cover's main colour (most area, favouring colourful over grey).
    var base: PaletteColor
    /// A second colour that clearly differs from `base` (for splatter, bursts).
    var accent: PaletteColor
    /// How colourful the cover is overall, 0 (greyscale) … 1.
    var colorfulness: Double

    static let neutral = AlbumPalette(
        base: PaletteColor(red: 0.84, green: 0.49, blue: 0.21),
        accent: PaletteColor(red: 0.95, green: 0.88, blue: 0.74),
        colorfulness: 0.5
    )

    /// The room behind the record: the base colour, kept mid-tone so both the
    /// cover and white text stay legible on it.
    var background: PaletteColor {
        if colorfulness < 0.12 {
            // Black-and-white covers get a warm grey rather than a dead one.
            return PaletteColor(red: 0.2, green: 0.19, blue: 0.18)
        }
        return base.adjusted(saturation: { $0 * 0.72 }, brightness: { min(0.58, max(0.26, $0 * 0.8)) })
    }

    /// The vinyl itself: a clean, saturated version of the base colour.
    var vinyl: PaletteColor {
        if colorfulness < 0.12 { return PaletteColor(red: 0.82, green: 0.82, blue: 0.84) }
        return base.adjusted(saturation: { min(0.85, max(0.45, $0 * 1.1)) }, brightness: { min(0.92, max(0.6, $0 + 0.15)) })
    }

    /// The paper label: a pale wash of the accent.
    var label: PaletteColor { accent.mixed(with: .white, 0.55) }

    /// Ink that reads on `label`.
    var labelInk: PaletteColor { label.luminance > 0.6 ? PaletteColor(red: 0.12, green: 0.12, blue: 0.12) : .white }

    // MARK: Extraction

    /// Reads a cover from disk and finds its palette. Runs in ~2 ms on a 32 px thumbnail.
    static func extract(fromFile url: URL) -> AlbumPalette? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap(extract(from:))
    }

    static func extract(fromData data: Data) -> AlbumPalette? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap(extract(from:))
    }

    private static func extract(from source: CGImageSource) -> AlbumPalette? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 32,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        // Colourful pixels group by hue family (12 × 30°) regardless of
        // brightness, so a blue sea in many shades counts as one blue; greys
        // group by brightness. Each pixel counts by how vivid it is: the
        // colour people remember a cover by, not merely the largest area.
        struct Bucket { var r = 0.0, g = 0.0, b = 0.0, weight = 0.0 }
        var buckets: [Int: Bucket] = [:]
        var totalSaturation = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let c = PaletteColor(red: Double(pixels[i]) / 255, green: Double(pixels[i + 1]) / 255, blue: Double(pixels[i + 2]) / 255)
            let (hue, sat, bri) = c.hsb
            totalSaturation += sat
            let chromatic = sat >= 0.2 && bri >= 0.18
            let key = chromatic ? Int(hue * 12) % 12 : 100 + min(2, Int(bri * 3))
            // Near-black backdrops and paper-white margins count for little.
            let tone = bri < 0.18 ? 0.25 : (bri > 0.93 && sat < 0.2 ? 0.5 : 1)
            let weight = (0.1 + 3 * sat * sat) * tone
            var bucket = buckets[key, default: Bucket()]
            bucket.r += c.red * weight; bucket.g += c.green * weight; bucket.b += c.blue * weight
            bucket.weight += weight
            buckets[key] = bucket
        }
        let pixelCount = Double(w * h)
        let ranked = buckets.values
            .map { bucket -> (color: PaletteColor, score: Double) in
                (PaletteColor(red: bucket.r / bucket.weight, green: bucket.g / bucket.weight, blue: bucket.b / bucket.weight), bucket.weight)
            }
            .sorted { $0.score > $1.score }
        guard let base = ranked.first?.color else { return nil }

        let baseHSB = base.hsb
        // Prefer a genuinely different colour (the flowers against the
        // table); fall back to a light/dark contrast, then to a shade of base.
        let others = ranked.dropFirst()
        let differentHue = others.first { candidate in
            let c = candidate.color.hsb
            var hueGap = abs(c.hue - baseHSB.hue)
            hueGap = min(hueGap, 1 - hueGap)
            return c.saturation > 0.2 && hueGap > 0.06 && candidate.score > ranked[0].score * 0.04
        }
        let contrast = others.first { abs($0.color.hsb.brightness - baseHSB.brightness) > 0.35 }
        let accent = (differentHue ?? contrast)?.color
            ?? base.adjusted(saturation: { $0 * 0.6 }, brightness: { $0 > 0.5 ? $0 - 0.4 : $0 + 0.45 })

        return AlbumPalette(base: base, accent: accent, colorfulness: min(1, totalSaturation / pixelCount * 1.6))
    }
}
