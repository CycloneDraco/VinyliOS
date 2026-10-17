import Combine
import Foundation

/// The looks Vinyl can take. `sleeve` is drawn natively (light on battery,
/// made for an always-on display); the others are the three.js scenes from
/// Vinyl for macOS.
enum VinylScene: String, CaseIterable, Identifiable {
    case sleeve
    case turntable
    case listeningRoom = "listening-room"
    case afterHours = "after-hours"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sleeve: return "Sleeve"
        case .turntable: return "Turntable"
        case .listeningRoom: return "Listening Room"
        case .afterHours: return "After Hours"
        }
    }

    var subtitle: String {
        switch self {
        case .sleeve: return "Cover and record, made for a stand"
        case .turntable: return "Top-down 3D deck on a desk"
        case .listeningRoom: return "3D room in golden afternoon sun"
        case .afterHours: return "3D room, lamp-lit late at night"
        }
    }

    var symbol: String {
        switch self {
        case .sleeve: return "square.on.circle"
        case .turntable: return "record.circle"
        case .listeningRoom: return "sun.max"
        case .afterHours: return "moon.stars"
        }
    }

    /// Rendered by the bundled three.js renderer rather than SwiftUI.
    var usesRenderer: Bool { self != .sleeve }

    /// Mirrors `defaultSize` in Vinyl for macOS: rooms open wide, the deck closer.
    var defaultSize: Double { self == .turntable ? 0.55 : 0.2 }
}

enum LabelStyle: String, CaseIterable, Identifiable {
    case label, picture
    var id: String { rawValue }
    var title: String { self == .label ? "Printed Label" : "Picture Disc" }
}

enum SleeveBackground: String, CaseIterable, Identifiable {
    case album, cover, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .album: return "Album Colour"
        case .cover: return "Blurred Cover"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// The pressing: what the record itself is made of, tinted from the cover.
enum VinylStyle: String, CaseIterable, Identifiable {
    case automatic, translucent, splatter, burst, classic
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Match the Album"
        case .translucent: return "Clear Colour"
        case .splatter: return "Splatter"
        case .burst: return "Starburst"
        case .classic: return "Classic Black"
        }
    }

    /// `.automatic` picks a pressing per album, so a shelf of records varies
    /// the way a real one does; the choice is stable for each album.
    func resolved(for palette: AlbumPalette, albumKey: String) -> VinylStyle {
        guard self == .automatic else { return self }
        if palette.colorfulness < 0.12 { return .translucent }
        let options: [VinylStyle] = [.translucent, .splatter, .burst, .splatter]
        let hash = albumKey.utf8.reduce(UInt32(2166136261)) { ($0 ^ UInt32($1)) &* 16777619 }
        return options[Int(hash % UInt32(options.count))]
    }
}

enum SourcePreference: String, CaseIterable, Identifiable {
    case automatic, spotify, appleMusic
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .spotify: return "Spotify"
        case .appleMusic: return "Apple Music"
        }
    }
}

enum EnergyMode: String, CaseIterable, Identifiable {
    case automatic, quality, saver
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .quality: return "Best Quality"
        case .saver: return "Battery Saver"
        }
    }
    var detail: String {
        switch self {
        case .automatic: return "Battery Saver kicks in with Low Power Mode"
        case .quality: return "Smoothest motion, full resolution"
        case .saver: return "30 fps and lighter 3D rendering"
        }
    }
}

/// User settings, persisted in UserDefaults.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    @Published var scene: VinylScene { didSet { defaults.set(scene.rawValue, forKey: Keys.scene) } }
    /// Zoom of each 3D scene, 0 (widest) … 1 (closest), keyed by scene.
    @Published var sceneSizes: [String: Double] { didSet { defaults.set(sceneSizes, forKey: Keys.sceneSizes) } }
    @Published var labelStyle: LabelStyle { didSet { defaults.set(labelStyle.rawValue, forKey: Keys.labelStyle) } }
    @Published var sleeveBackground: SleeveBackground { didSet { defaults.set(sleeveBackground.rawValue, forKey: Keys.background) } }
    @Published var vinylStyle: VinylStyle { didSet { defaults.set(vinylStyle.rawValue, forKey: Keys.vinylStyle) } }
    @Published var showTrackInfo: Bool { didSet { defaults.set(showTrackInfo, forKey: Keys.trackInfo) } }
    @Published var spinWhenIdle: Bool { didSet { defaults.set(spinWhenIdle, forKey: Keys.idleSpin) } }

    @Published var keepAwake: Bool { didSet { defaults.set(keepAwake, forKey: Keys.keepAwake) } }
    /// 0 = full brightness … 0.85 = very dim (a black veil over the scene).
    @Published var dimming: Double { didSet { defaults.set(dimming, forKey: Keys.dimming) } }
    @Published var showClock: Bool { didSet { defaults.set(showClock, forKey: Keys.clock) } }
    /// Nudges the scene a few points every few minutes so OLED screens don't burn in.
    @Published var pixelShift: Bool { didSet { defaults.set(pixelShift, forKey: Keys.pixelShift) } }

    @Published var liveActivity: Bool { didSet { defaults.set(liveActivity, forKey: Keys.liveActivity) } }
    @Published var source: SourcePreference { didSet { defaults.set(source.rawValue, forKey: Keys.source) } }
    @Published var appleMusicEnabled: Bool { didSet { defaults.set(appleMusicEnabled, forKey: Keys.appleMusic) } }
    @Published var energy: EnergyMode { didSet { defaults.set(energy.rawValue, forKey: Keys.energy) } }

    func size(for scene: VinylScene) -> Double {
        sceneSizes[scene.rawValue] ?? scene.defaultSize
    }

    /// The selected 3D scene's zoom (what the Size slider edits).
    var currentSize: Double {
        get { size(for: scene) }
        set { sceneSizes[scene.rawValue] = min(max(newValue, 0), 1) }
    }

    var hasLaunchedBefore: Bool {
        get { defaults.bool(forKey: Keys.launched) }
        set { defaults.set(newValue, forKey: Keys.launched) }
    }

    private init() {
        defaults.register(defaults: [
            Keys.trackInfo: true,
            Keys.idleSpin: true,
            Keys.keepAwake: true,
            Keys.pixelShift: true,
            Keys.liveActivity: true,
            Keys.dimming: 0.0,
        ])
        scene = VinylScene(rawValue: defaults.string(forKey: Keys.scene) ?? "") ?? .sleeve
        sceneSizes = (defaults.dictionary(forKey: Keys.sceneSizes) ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
        labelStyle = LabelStyle(rawValue: defaults.string(forKey: Keys.labelStyle) ?? "") ?? .label
        sleeveBackground = SleeveBackground(rawValue: defaults.string(forKey: Keys.background) ?? "") ?? .album
        vinylStyle = VinylStyle(rawValue: defaults.string(forKey: Keys.vinylStyle) ?? "") ?? .automatic
        showTrackInfo = defaults.bool(forKey: Keys.trackInfo)
        spinWhenIdle = defaults.bool(forKey: Keys.idleSpin)
        keepAwake = defaults.bool(forKey: Keys.keepAwake)
        dimming = defaults.double(forKey: Keys.dimming)
        showClock = defaults.bool(forKey: Keys.clock)
        pixelShift = defaults.bool(forKey: Keys.pixelShift)
        liveActivity = defaults.bool(forKey: Keys.liveActivity)
        source = SourcePreference(rawValue: defaults.string(forKey: Keys.source) ?? "") ?? .automatic
        appleMusicEnabled = defaults.bool(forKey: Keys.appleMusic)
        energy = EnergyMode(rawValue: defaults.string(forKey: Keys.energy) ?? "") ?? .automatic
    }

    private enum Keys {
        static let scene = "scene"
        static let sceneSizes = "sceneSizes"
        static let labelStyle = "labelStyle"
        static let background = "sleeveBackground"
        static let vinylStyle = "vinylStyle"
        static let trackInfo = "showTrackInfo"
        static let idleSpin = "spinWhenIdle"
        static let keepAwake = "keepAwake"
        static let dimming = "dimming"
        static let clock = "showClock"
        static let pixelShift = "pixelShift"
        static let liveActivity = "liveActivity"
        static let source = "source"
        static let appleMusic = "appleMusicEnabled"
        static let energy = "energy"
        static let launched = "hasLaunchedBefore"
    }
}
