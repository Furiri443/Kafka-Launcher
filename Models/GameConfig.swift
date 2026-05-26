import Foundation

// MARK: - Game Config (Config per game — full feature set)

struct GameConfig: Codable, Equatable {
    var gameType: GameType
    var installDirectory: String?
    var voiceLanguage: VoiceLanguage = .japanese
    var installedVersion: String?

    // Wine settings
    var useGlobalWineSettings: Bool = true
    var wineSourceMode: WineSourceMode = .github
    var customWinePath: String = ""
    var wineDistribution: String = WineManager.defaultDistribution.id // Default is Stable
    var retinaMode: Bool = true         // retinaMode support
    var leftCommandIsCtrl: Bool = true  // map Left Command to Control

    // Graphics settings
    var enableDXMT: Bool = true
    var installedDXMTVersion: String?
    var metalHUD: Bool = false
    var enableHDR: Bool = false

    // Resolution settings
    var customResolution: Bool = false
    var resolutionWidth: Int = 1920
    var resolutionHeight: Int = 1080

    // Network settings
    var proxyEnabled: Bool = false
    var proxyHost: String = ""
    var blockNetwork: Bool = false
    
    // Private Server Settings
    var usePrivateServer: Bool = false
    var privateServerAddress: String = "127.0.0.1:21000"
    var customProxyPath: String = ""

    // Patch settings
    var useSteamPatch: Bool = false     // Steam emulation DLLs
    var enableReShade: Bool = false
    var workaround3: Bool = false       // workaround3 tag disable

    // DXMT environment
    var winemsync: Bool = true          // WINEMSYNC=1

    // Pre-download flag
    var predownloadedAll: Bool = false

    enum VoiceLanguage: String, Codable, CaseIterable, Identifiable {
        case chinese = "zh-cn"
        case english = "en-us"
        case japanese = "ja-jp"
        case korean = "ko-kr"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .chinese: return "Chinese"
            case .english: return "English"
            case .japanese: return "Japanese"
            case .korean: return "Korean"
            }
        }
    }

    var installURL: URL? {
        guard let dir = installDirectory else { return nil }
        return URL(fileURLWithPath: dir)
    }
}

// MARK: - Wine Source Mode

enum WineSourceMode: String, Codable, CaseIterable {
    case github = "github"   // Download / managed by the launcher
    case custom = "custom"   // User-supplied Wine folder

    var displayName: String {
        switch self {
        case .github: return "Download from GitHub"
        case .custom: return "Custom Folder"
        }
    }

    var icon: String {
        switch self {
        case .github: return "arrow.down.circle"
        case .custom: return "folder"
        }
    }
}

// MARK: - Launcher Settings

struct LauncherSettings: Codable {
    var selectedGame: GameType = .genshinImpact
    var gameConfigs: [GameType: GameConfig] = [:]
    var defaultDownloadDirectory: String = NSHomeDirectory() + "/Games"
    var language: String = "en"

    // Wine global settings
    var selectedWineDistribution: String = WineManager.defaultDistribution.id
    var wineSourceMode: WineSourceMode = .github
    var customWinePath: String = ""     // Path to Wine folder when mode == .custom

    func config(for game: GameType) -> GameConfig {
        gameConfigs[game] ?? GameConfig(gameType: game)
    }

    mutating func updateConfig(for game: GameType, _ update: (inout GameConfig) -> Void) {
        if gameConfigs[game] == nil {
            gameConfigs[game] = GameConfig(gameType: game)
        }
        update(&gameConfigs[game]!)
    }

    // MARK: - Persistence

    private static let storageKey = "kafka_launcher_settings"

    static func load() -> LauncherSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              var settings = try? JSONDecoder().decode(LauncherSettings.self, from: data) else {
            return LauncherSettings()
        }
        // Migrate old Wine distribution IDs
        if !WineManager.distributions.contains(where: { $0.id == settings.selectedWineDistribution }) {
            settings.selectedWineDistribution = WineManager.defaultDistribution.id
            settings.save()
        }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
