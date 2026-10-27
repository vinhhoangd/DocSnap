import Foundation

/// Look applied to a page after perspective correction.
enum ScanFilter: String, Codable, CaseIterable, Identifiable {
    case original
    case magicColor
    case grayscale
    case blackWhite
    case lighten

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .original: "Original"
        case .magicColor: "Magic Color"
        case .grayscale: "Grayscale"
        case .blackWhite: "B&W"
        case .lighten: "Lighten"
        }
    }

    var systemImage: String {
        switch self {
        case .original: "photo"
        case .magicColor: "wand.and.stars"
        case .grayscale: "circle.lefthalf.filled"
        case .blackWhite: "doc.plaintext"
        case .lighten: "sun.max"
        }
    }

    /// Unknown raw values (e.g. from a newer app version) fall back to Magic Color instead of failing to load.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ScanFilter(rawValue: raw) ?? .magicColor
    }
}
