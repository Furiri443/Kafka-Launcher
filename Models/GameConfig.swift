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
    var useFireflyPS: Bool = false
    var privateServerAddress: String = "127.0.0.1:21000"
    var customProxyPath: String = ""
    var privateServerAcceptRun: String = ""

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

    // MARK: - Codable & Initializers
    
    enum CodingKeys: String, CodingKey {
        case gameType, installDirectory, voiceLanguage, installedVersion
        case useGlobalWineSettings, wineSourceMode, customWinePath, wineDistribution, retinaMode, leftCommandIsCtrl
        case enableDXMT, installedDXMTVersion, metalHUD, enableHDR
        case customResolution, resolutionWidth, resolutionHeight
        case proxyEnabled, proxyHost, blockNetwork
        case usePrivateServer, useFireflyPS, privateServerAddress, customProxyPath, privateServerAcceptRun
        case useSteamPatch, enableReShade, workaround3
        case winemsync
        case predownloadedAll
    }

    init(gameType: GameType) {
        self.gameType = gameType
        self.installDirectory = nil
        self.voiceLanguage = .japanese
        self.installedVersion = nil
        self.useGlobalWineSettings = true
        self.wineSourceMode = .github
        self.customWinePath = ""
        self.wineDistribution = WineManager.defaultDistribution.id
        self.retinaMode = true
        self.leftCommandIsCtrl = true
        self.enableDXMT = true
        self.installedDXMTVersion = nil
        self.metalHUD = false
        self.enableHDR = false
        self.customResolution = false
        self.resolutionWidth = 1920
        self.resolutionHeight = 1080
        self.proxyEnabled = false
        self.proxyHost = ""
        self.blockNetwork = false
        self.usePrivateServer = false
        self.useFireflyPS = false
        self.privateServerAddress = "127.0.0.1:21000"
        self.customProxyPath = ""
        self.privateServerAcceptRun = ""
        self.useSteamPatch = false
        self.enableReShade = false
        self.workaround3 = false
        self.winemsync = true
        self.predownloadedAll = false
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.gameType = try container.decode(GameType.self, forKey: .gameType)
        self.installDirectory = try container.decodeIfPresent(String.self, forKey: .installDirectory)
        self.voiceLanguage = try container.decodeIfPresent(VoiceLanguage.self, forKey: .voiceLanguage) ?? .japanese
        self.installedVersion = try container.decodeIfPresent(String.self, forKey: .installedVersion)
        
        self.useGlobalWineSettings = try container.decodeIfPresent(Bool.self, forKey: .useGlobalWineSettings) ?? true
        self.wineSourceMode = try container.decodeIfPresent(WineSourceMode.self, forKey: .wineSourceMode) ?? .github
        self.customWinePath = try container.decodeIfPresent(String.self, forKey: .customWinePath) ?? ""
        self.wineDistribution = try container.decodeIfPresent(String.self, forKey: .wineDistribution) ?? WineManager.defaultDistribution.id
        self.retinaMode = try container.decodeIfPresent(Bool.self, forKey: .retinaMode) ?? true
        self.leftCommandIsCtrl = try container.decodeIfPresent(Bool.self, forKey: .leftCommandIsCtrl) ?? true
        
        self.enableDXMT = try container.decodeIfPresent(Bool.self, forKey: .enableDXMT) ?? true
        self.installedDXMTVersion = try container.decodeIfPresent(String.self, forKey: .installedDXMTVersion)
        self.metalHUD = try container.decodeIfPresent(Bool.self, forKey: .metalHUD) ?? false
        self.enableHDR = try container.decodeIfPresent(Bool.self, forKey: .enableHDR) ?? false
        
        self.customResolution = try container.decodeIfPresent(Bool.self, forKey: .customResolution) ?? false
        self.resolutionWidth = try container.decodeIfPresent(Int.self, forKey: .resolutionWidth) ?? 1920
        self.resolutionHeight = try container.decodeIfPresent(Int.self, forKey: .resolutionHeight) ?? 1080
        
        self.proxyEnabled = try container.decodeIfPresent(Bool.self, forKey: .proxyEnabled) ?? false
        self.proxyHost = try container.decodeIfPresent(String.self, forKey: .proxyHost) ?? ""
        self.blockNetwork = try container.decodeIfPresent(Bool.self, forKey: .blockNetwork) ?? false
        
        self.usePrivateServer = try container.decodeIfPresent(Bool.self, forKey: .usePrivateServer) ?? false
        self.useFireflyPS = try container.decodeIfPresent(Bool.self, forKey: .useFireflyPS) ?? false
        self.privateServerAddress = try container.decodeIfPresent(String.self, forKey: .privateServerAddress) ?? "127.0.0.1:21000"
        self.customProxyPath = try container.decodeIfPresent(String.self, forKey: .customProxyPath) ?? ""
        self.privateServerAcceptRun = try container.decodeIfPresent(String.self, forKey: .privateServerAcceptRun) ?? ""
        
        self.useSteamPatch = try container.decodeIfPresent(Bool.self, forKey: .useSteamPatch) ?? false
        self.enableReShade = try container.decodeIfPresent(Bool.self, forKey: .enableReShade) ?? false
        self.workaround3 = try container.decodeIfPresent(Bool.self, forKey: .workaround3) ?? false
        self.winemsync = try container.decodeIfPresent(Bool.self, forKey: .winemsync) ?? true
        self.predownloadedAll = try container.decodeIfPresent(Bool.self, forKey: .predownloadedAll) ?? false
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
    
    // Toggle to allow running older game versions and skip update checking
    var runOldVersion: Bool = false

    func config(for game: GameType) -> GameConfig {
        gameConfigs[game] ?? GameConfig(gameType: game)
    }

    mutating func updateConfig(for game: GameType, _ update: (inout GameConfig) -> Void) {
        if gameConfigs[game] == nil {
            gameConfigs[game] = GameConfig(gameType: game)
        }
        update(&gameConfigs[game]!)
    }

    // MARK: - Codable Custom Setup
    
    enum CodingKeys: String, CodingKey {
        case selectedGame
        case gameConfigs
        case defaultDownloadDirectory
        case language
        case selectedWineDistribution
        case wineSourceMode
        case customWinePath
        case runOldVersion
    }

    init() {
        self.selectedGame = .genshinImpact
        self.gameConfigs = [:]
        self.defaultDownloadDirectory = NSHomeDirectory() + "/Games"
        self.language = "en"
        self.selectedWineDistribution = WineManager.defaultDistribution.id
        self.wineSourceMode = .github
        self.customWinePath = ""
        self.runOldVersion = false
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.selectedGame = try container.decodeIfPresent(GameType.self, forKey: .selectedGame) ?? .genshinImpact
        self.gameConfigs = try container.decodeIfPresent([GameType: GameConfig].self, forKey: .gameConfigs) ?? [:]
        self.defaultDownloadDirectory = try container.decodeIfPresent(String.self, forKey: .defaultDownloadDirectory) ?? (NSHomeDirectory() + "/Games")
        self.language = try container.decodeIfPresent(String.self, forKey: .language) ?? "en"
        self.selectedWineDistribution = try container.decodeIfPresent(String.self, forKey: .selectedWineDistribution) ?? WineManager.defaultDistribution.id
        self.wineSourceMode = try container.decodeIfPresent(WineSourceMode.self, forKey: .wineSourceMode) ?? .github
        self.customWinePath = try container.decodeIfPresent(String.self, forKey: .customWinePath) ?? ""
        self.runOldVersion = try container.decodeIfPresent(Bool.self, forKey: .runOldVersion) ?? false
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
