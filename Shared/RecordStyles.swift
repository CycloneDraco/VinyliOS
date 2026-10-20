import Foundation

// Used by the app and the widgets.

enum LabelStyle: String, CaseIterable, Identifiable {
    case label, picture
    var id: String { rawValue }
    var title: String { self == .label ? "Printed Label" : "Picture Disc" }
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
