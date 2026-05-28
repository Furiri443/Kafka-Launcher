import Foundation

// MARK: - Game Server API

actor GameServerAPI {
    static let shared = GameServerAPI()

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }()

    // Fetch launcher backgrounds/content
    func fetchGameBackground(for gameInfo: GameInfo) async throws -> GameInfo.LauncherContent {
        guard let url = URL(string: gameInfo.serverConfig.advURL) else {
            throw APIError.invalidResponse
        }
        let (data, _) = try await session.data(from: url)

        let response = try JSONDecoder().decode(
            HypConnectResponse<AllGameBasicInfoData>.self,
            from: data
        )

        guard let game = response.data.game_info_list.first(where: { $0.game.biz == gameInfo.type.bizId }),
              let bg = game.backgrounds.first else {
            throw APIError.gameNotFound(gameInfo.type.bizId)
        }

        return GameInfo.LauncherContent(
            backgroundURL: URL(string: bg.background.url),
            backgroundVideoURL: bg.video?.url.flatMap { URL(string: $0) },
            logoURL: nil,
            iconURL: bg.icon.flatMap { URL(string: $0.url) },
            themeURL: bg.theme?.url.flatMap { URL(string: $0) }
        )
    }

    // Fetch latest version info
    func fetchLatestVersion(for gameInfo: GameInfo) async throws -> GamePackageManifest {
        guard let url = URL(string: gameInfo.serverConfig.updateURL) else {
            throw APIError.invalidResponse
        }
        let (data, _) = try await session.data(from: url)

        let response = try JSONDecoder().decode(
            HypConnectResponse<GamePackagesData>.self,
            from: data
        )

        guard let game = response.data.game_packages.first(where: { $0.game.biz == gameInfo.type.bizId }) else {
            throw APIError.gameNotFound(gameInfo.type.bizId)
        }
        return game
    }

    enum APIError: LocalizedError {
        case gameNotFound(String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .gameNotFound(let biz): return "Game not found: \(biz)"
            case .invalidResponse: return "Invalid server response"
            }
        }
    }
}
