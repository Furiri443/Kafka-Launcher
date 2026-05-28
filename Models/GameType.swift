import SwiftUI

// MARK: - Game Type

enum GameType: String, CaseIterable, Identifiable, Codable {
    case genshinImpact = "genshin_impact"
    case honkaiStarRail = "honkai_star_rail"
    case zenlessZoneZero = "zenless_zone_zero"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .genshinImpact: return "Genshin Impact"
        case .honkaiStarRail: return "Honkai: Star Rail"
        case .zenlessZoneZero: return "Zenless Zone Zero"
        }
    }

    var shortName: String {
        switch self {
        case .genshinImpact: return "GI"
        case .honkaiStarRail: return "HSR"
        case .zenlessZoneZero: return "ZZZ"
        }
    }

    var iconSystemName: String {
        switch self {
        case .genshinImpact: return "wind"
        case .honkaiStarRail: return "tram.fill"
        case .zenlessZoneZero: return "bolt.fill"
        }
    }

    var accentColor: Color {
        switch self {
        case .genshinImpact: return Color(red: 0.38, green: 0.76, blue: 0.85)
        case .honkaiStarRail: return Color(red: 0.85, green: 0.65, blue: 0.95)
        case .zenlessZoneZero: return Color(red: 1.0, green: 0.78, blue: 0.28)
        }
    }

    var gradientColors: [Color] {
        switch self {
        case .genshinImpact:
            return [
                Color(red: 0.10, green: 0.40, blue: 0.55),
                Color(red: 0.20, green: 0.65, blue: 0.80),
            ]
        case .honkaiStarRail:
            return [
                Color(red: 0.20, green: 0.10, blue: 0.35),
                Color(red: 0.55, green: 0.30, blue: 0.75),
            ]
        case .zenlessZoneZero:
            return [
                Color(red: 0.15, green: 0.15, blue: 0.20),
                Color(red: 0.45, green: 0.35, blue: 0.15),
            ]
        }
    }

    var isDarkBackground: Bool {
        switch self {
        case .genshinImpact: return true
        case .honkaiStarRail: return true
        case .zenlessZoneZero: return false // ZZZ has a bright background
        }
    }

    // Server biz IDs matching game API patterns
    var bizId: String {
        switch self {
        case .genshinImpact: return "hk4e_global"
        case .honkaiStarRail: return "hkrpg_global"
        case .zenlessZoneZero: return "nap_global"
        }
    }

    var executable: String {
        switch self {
        case .genshinImpact: return "GenshinImpact.exe"
        case .honkaiStarRail: return "StarRail.exe"
        case .zenlessZoneZero: return "ZenlessZoneZero.exe"
        }
    }

    var dataDir: String {
        switch self {
        case .genshinImpact: return "GenshinImpact_Data"
        case .honkaiStarRail: return "StarRail_Data"
        case .zenlessZoneZero: return "ZenlessZoneZero_Data"
        }
    }
}
