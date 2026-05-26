import SwiftUI

// MARK: - Game Manager (full implementation of game launch pipeline)

@Observable
class GameManager {
    var games: [GameType: GameInfo]
    var gameStates: [GameType: GameState] = [:]
    var settings: LauncherSettings
    var selectedGame: GameType
    var errorMessage: String?
    var showErrorAlert: Bool = false

    let downloadManager = DownloadManager()
    let wineManager = WineManager()
    let api = GameServerAPI.shared
    private var activeProxyProcess: Process?

    init() {
        let settings = LauncherSettings.load()
        self.settings = settings
        self.selectedGame = settings.selectedGame

        var gamesMap: [GameType: GameInfo] = [:]
        var statesMap: [GameType: GameState] = [:]
        for info in GameInfo.defaultGames {
            gamesMap[info.type] = info
            statesMap[info.type] = .notInstalled
        }
        self.games = gamesMap
        self.gameStates = statesMap

        Task { await checkAllGameStates() }
        Task { await fetchAllBackgrounds() }
        Task { await checkWineStatus() }
    }

    var currentGame: GameInfo {
        games[selectedGame] ?? GameInfo.defaultGames[0]
    }

    var currentState: GameState {
        gameStates[selectedGame] ?? .notInstalled
    }

    // MARK: - State Management

    func selectGame(_ type: GameType) {
        selectedGame = type
        settings.selectedGame = type
        settings.save()
    }

    @MainActor
    func reportError(_ message: String, for type: GameType) {
        gameStates[type] = .error(message: message)
        self.errorMessage = message
        self.showErrorAlert = true
    }

    // MARK: - Wine Status Check

    func checkWineStatus() async {
        // Sync settings → WineManager before checking
        applyWineSettings()

        let status = wineManager.checkWineAvailability()
        // Only auto-download when using GitHub mode and wine is missing
        if !status.isReady && settings.wineSourceMode == .github {
            print("Wine not ready: \(status.displayName). Auto-downloading...")
            let selectedId = settings.selectedWineDistribution
            let distro = WineManager.distributions.first { $0.id == selectedId }
            await installWine(distribution: distro)
        }
    }

    /// Apply current Wine settings from LauncherSettings → WineManager
    func applyWineSettings(for gameType: GameType? = nil) {
        let targetType = gameType ?? selectedGame
        let config = settings.config(for: targetType)
        
        let mode = config.useGlobalWineSettings ? settings.wineSourceMode : config.wineSourceMode
        let path = config.useGlobalWineSettings ? settings.customWinePath : config.customWinePath
        
        switch mode {
        case .custom:
            wineManager.customWinePath = path
        case .github:
            wineManager.customWinePath = ""
        }
    }

    // MARK: - Private Server Proxy Helpers
    
    private func findFreePort() -> Int {
        let socket = socket(AF_INET, SOCK_STREAM, 0)
        if socket == -1 { return 8080 }
        defer { close(socket) }
        
        var addr = sockaddr_in()
        addr.sin_len = __uint8_t(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian
        
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindResult == -1 { return 8080 }
        
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getsocknameResult = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socket, $0, &len)
            }
        }
        if getsocknameResult == -1 { return 8080 }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
    
    private func ensureProxyBinaryAvailable(config: GameConfig) async throws -> String {
        let fm = FileManager.default
        let targetPath = WineManager.basePath + "/firefly-go-proxy"
        
        // 1. Check user configured custom path
        if !config.customProxyPath.isEmpty && fm.fileExists(atPath: config.customProxyPath) {
            return config.customProxyPath
        }
        
        // 2. Check default path in ~/.kafka-launcher
        if fm.fileExists(atPath: targetPath) {
            return targetPath
        }
        
        // 3. Download from Gitea releases
        do {
            try await downloadProxyFromGitea(to: targetPath)
            if fm.fileExists(atPath: targetPath) {
                return targetPath
            }
        } catch {
            print("[Proxy] Failed to download from Gitea: \(error.localizedDescription). Trying fallbacks...")
        }
        
        // 4. Dev fallback: Copy from workspace FireflyGo_Proxy
        let devProxyPath = "/Volumes/OCungRoi/PRJ/FireflyGo_Proxy/firefly-go-proxy"
        if fm.fileExists(atPath: devProxyPath) {
            try? fm.createDirectory(atPath: WineManager.basePath, withIntermediateDirectories: true)
            try? fm.copyItem(atPath: devProxyPath, toPath: targetPath)
            if fm.fileExists(atPath: targetPath) {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: targetPath)
                return targetPath
            }
        }
        
        // 5. Dev fallback compile: Call go build if src exists but binary doesn't
        let devSrcDir = "/Volumes/OCungRoi/PRJ/FireflyGo_Proxy"
        if fm.fileExists(atPath: devSrcDir + "/main.go") {
            print("[Proxy] Dev source found. Compiling via go build...")
            do {
                let compileCode = try await ProcessRunner.run(
                    "/usr/bin/go",
                    arguments: ["build", "-o", targetPath],
                    environment: ["PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"],
                    standardOutput: FileHandle.nullDevice,
                    standardError: FileHandle.nullDevice
                )
                if compileCode == 0 && fm.fileExists(atPath: targetPath) {
                    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: targetPath)
                    return targetPath
                }
            } catch {
                print("[Proxy] Compile failed: \(error)")
            }
        }
        
        throw NSError(domain: "ProxyManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "Could not find firefly-go-proxy binary at \(targetPath). Please reconfigure or run go build first."])
    }

    private func downloadProxyFromGitea(to targetPath: String) async throws {
        let url = URL(string: "https://git.kain.io.vn/api/v1/repos/Firefly-Shelter/FireflyGo_Proxy/releases/latest")!
        let (data, response) = try await URLSession.shared.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "ProxyManager", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch latest release from Gitea API."])
        }
        
        struct GiteaRelease: Codable {
            struct Asset: Codable {
                let name: String
                let browser_download_url: String
            }
            let assets: [Asset]
        }
        
        let release = try JSONDecoder().decode(GiteaRelease.self, from: data)
        
        #if arch(arm64)
        let targetAssetName = "firefly-go-proxy-macos-arm64"
        #else
        let targetAssetName = "firefly-go-proxy-macos-amd64"
        #endif
        
        guard let asset = release.assets.first(where: { $0.name == targetAssetName }),
              let downloadURL = URL(string: asset.browser_download_url) else {
            throw NSError(domain: "ProxyManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "Could not find asset '\(targetAssetName)' in the latest release."])
        }
        
        print("[Proxy] Downloading latest proxy asset: \(asset.name) from \(asset.browser_download_url)")
        
        let (downloadedLocation, downloadResponse) = try await URLSession.shared.download(from: downloadURL)
        guard let downloadHttpResponse = downloadResponse as? HTTPURLResponse, (200...299).contains(downloadHttpResponse.statusCode) else {
            throw NSError(domain: "ProxyManager", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to download proxy binary from Gitea."])
        }
        
        let fm = FileManager.default
        try fm.createDirectory(atPath: (targetPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if fm.fileExists(atPath: targetPath) {
            try fm.removeItem(atPath: targetPath)
        }
        try fm.moveItem(at: downloadedLocation, to: URL(fileURLWithPath: targetPath))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: targetPath)
        print("[Proxy] Proxy binary successfully downloaded and set to executable.")
    }

    // MARK: - Install Wine

    func installWine(distribution: WineDistribution? = nil) async {
        do {
            try await wineManager.installWine(distribution: distribution) { progress in
                print("Wine install: \(progress.description)")
            }

            // Auto-download DXMT after Wine is ready
            print("DXMT: Checking availability...")
            try await DXMTManager.ensureDXMTAvailable()
            print("DXMT: Ready")
        } catch {
            print("Wine installation failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Check All Game States (with version detection from Unity binaries)

    func checkAllGameStates() async {
        for type in GameType.allCases {
            let config = settings.config(for: type)
            if let dir = config.installDirectory, isGamePresent(type, at: dir) {
                await MainActor.run {
                    gameStates[type] = .checkingForUpdates
                }

                // Detect installed version from Unity binary files
                var detectedVersion = config.installedVersion
                if detectedVersion == nil {
                    detectedVersion = GameVersionDetector.detectInstalledVersion(
                        gameType: type, installDir: dir
                    )
                    if let v = detectedVersion {
                        settings.updateConfig(for: type) { config in
                            config.installedVersion = v
                        }
                        settings.save()
                    }
                }

                // Check for updates from HoYo API
                do {
                    let manifest = try await api.fetchLatestVersion(for: games[type]!)
                    if let latestVersion = manifest.main.major?.version,
                       let installed = detectedVersion ?? config.installedVersion,
                       latestVersion != installed {
                        await MainActor.run {
                            gameStates[type] = .needsUpdate(
                                currentVersion: installed,
                                latestVersion: latestVersion
                            )
                        }
                    } else {
                        await MainActor.run {
                            gameStates[type] = .ready
                        }
                    }
                } catch {
                    await MainActor.run {
                        gameStates[type] = .ready
                    }
                }
            } else {
                await MainActor.run {
                    gameStates[type] = .notInstalled
                }
            }
        }
    }

    private func isGamePresent(_ type: GameType, at dir: String) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir + "/" + type.executable) { return true }
        if fm.fileExists(atPath: dir + "/" + type.dataDir) { return true }
        return false
    }

    // MARK: - Locate Existing Game

    func locateGame(_ type: GameType) async {
        guard let url = await selectInstallDirectory(for: type) else { return }
        let dir = url.path

        if isGamePresent(type, at: dir) {
            // Detect version
            let version = GameVersionDetector.detectInstalledVersion(gameType: type, installDir: dir)

            await MainActor.run {
                settings.updateConfig(for: type) { config in
                    config.installDirectory = dir
                    config.installedVersion = version
                }
                settings.save()
            }
            await checkAllGameStates()
        } else {
            await MainActor.run {
                reportError("Game not found in selected directory", for: type)
            }
        }
    }

    func fetchAllBackgrounds() async {
        for type in GameType.allCases {
            guard var info = games[type] else { continue }
            do {
                let content = try await api.fetchGameBackground(for: info)
                info.launcherContent = content
                await MainActor.run {
                    games[type] = info
                }
            } catch {
                print("Failed to fetch background for \(type.displayName): \(error)")
            }
        }
    }

    // MARK: - Actions

    func performAction(for type: GameType) async {
        let state = gameStates[type] ?? .notInstalled
        switch state {
        case .notInstalled:
            await installGame(type)
        case .ready:
            await launchGame(type)
        case .needsUpdate:
            await updateGame(type)
        case .error:
            await checkAllGameStates()
            let newState = gameStates[type] ?? .notInstalled
            switch newState {
            case .notInstalled:
                await installGame(type)
            case .ready:
                await launchGame(type)
            case .needsUpdate:
                await updateGame(type)
            default:
                break
            }
        default:
            break
        }
    }

    func selectInstallDirectory(for type: GameType) async -> URL? {
        await MainActor.run {
            let panel = NSOpenPanel()
            panel.title = "Select Installation Directory for \(type.displayName)"
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let url = panel.url else { return nil }
            return url
        }
    }

    // MARK: - Install Game

    func installGame(_ type: GameType) async {
        guard let installURL = await selectInstallDirectory(for: type) else { return }

        await MainActor.run {
            settings.updateConfig(for: type) { config in
                config.installDirectory = installURL.path
            }
            settings.save()
            gameStates[type] = .installing(progress: 0, status: "Preparing...")
        }

        do {
            // Ensure Wine is ready
            if !wineManager.status.isReady {
                await MainActor.run {
                    gameStates[type] = .installing(progress: 0, status: "Installing Wine...")
                }
                try await wineManager.installWine { [weak self] progress in
                    Task { @MainActor in
                        self?.gameStates[type] = .installing(
                            progress: Double(progress.downloadProgress) * 0.2,
                            status: progress.description
                        )
                    }
                }
            }

            let manifest = try await api.fetchLatestVersion(for: games[type]!)
            guard let major = manifest.main.major,
                  let pkg = major.game_pkgs.first,
                  let url = URL(string: pkg.url) else {
                await MainActor.run { reportError("No download available", for: type) }
                return
            }

            // Download and extract game
            downloadManager.downloadAndExtract(
                url: url,
                to: installURL.path,
                id: type.rawValue,
                gameType: type,
                onProgress: { [weak self] progress, status in
                    Task { @MainActor in
                        self?.gameStates[type] = .installing(
                            progress: 0.2 + progress * 0.8,
                            status: status
                        )
                    }
                },
                onComplete: { [weak self] result in
                    Task { @MainActor in
                        switch result {
                        case .success:
                            self?.settings.updateConfig(for: type) { config in
                                config.installedVersion = major.version
                            }
                            self?.settings.save()
                            self?.gameStates[type] = .ready
                        case .failure(let error):
                            self?.reportError(error.localizedDescription, for: type)
                        }
                    }
                }
            )
        } catch {
            await MainActor.run {
                reportError(error.localizedDescription, for: type)
            }
        }
    }

    // MARK: - Update Game

    func updateGame(_ type: GameType) async {
        await MainActor.run {
            gameStates[type] = .updating(progress: 0, status: "Checking update...")
        }
        // For now, re-install (full Sophon diff-update would require the Python backend)
        await installGame(type)
    }

    // MARK: - Full 4-Phase Game Launch

    func launchGame(_ type: GameType) async {
        let config = settings.config(for: type)
        guard let installDir = config.installDirectory else {
            await MainActor.run { reportError("Game not installed", for: type) }
            return
        }

        await MainActor.run { gameStates[type] = .launching }

        var freePort = 8080
        var privateServerCertRegPath: String?
        var hdrRegPath: String?
        var resRegPath: String?
        var proxyRegPath: String?
        var certRegPath: String?
        var batchPath: String?
        
        let prefix = WineManager.defaultPrefixPath
        let launchLog = LaunchLogger(gameType: type)
        
        let currentDistroId = settings.selectedWineDistribution
        let currentDistro = WineManager.distributions.first { $0.id == currentDistroId }
        let renderBackend = currentDistro?.renderBackend ?? "dxmt"
        let useDXMT = config.enableDXMT && renderBackend == "dxmt"

        do {
            // Apply proper wine settings before launch
            applyWineSettings(for: type)
            
            launchLog.info("════════════════════════════════════════")
            launchLog.info("Launching \(type.displayName)")
            launchLog.info("Install dir: \(installDir)")
            launchLog.info("Wine binary: \(wineManager.getWineBinary())")
            launchLog.info("Wine mode: \(settings.config(for: type).useGlobalWineSettings ? "Global" : "Per-game custom")")
            launchLog.info("Wine prefix: \(prefix)")
            launchLog.info("Render backend: \(renderBackend) (DXMT enabled: \(useDXMT))")
            launchLog.info("════════════════════════════════════════")

            // 0. Start Private Server Proxy if enabled
            if config.usePrivateServer {
                launchLog.info("[Phase 1] Private Server mode enabled. Preparing proxy...")
                let proxyBin = try await ensureProxyBinaryAvailable(config: config)
                freePort = findFreePort()
                
                let process = Process()
                process.executableURL = URL(fileURLWithPath: proxyBin)
                process.arguments = ["-no-sys", "-p", String(freePort), "-r", config.privateServerAddress]
                process.currentDirectoryURL = URL(fileURLWithPath: WineManager.basePath)
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                
                launchLog.info("[Phase 1] Starting firefly-go-proxy at port \(freePort) redirecting to \(config.privateServerAddress)...")
                try process.run()
                self.activeProxyProcess = process
                
                // Wait a bit for CA cert file generation
                try await Task.sleep(nanoseconds: 1_000_000_000)
                
                let caCertPath = WineManager.basePath + "/firefly-go-proxy-ca.crt"
                guard FileManager.default.fileExists(atPath: caCertPath) else {
                    throw NSError(domain: "ProxyManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "Failed to start private server proxy: CA cert file not found at \(caCertPath)."])
                }
                
                launchLog.info("[Phase 1] Importing Firefly CA cert into Wine prefix...")
                guard let certPath = try await RegistryManager.importCertificate(
                    at: caCertPath,
                    wineManager: wineManager,
                    prefix: prefix
                ) else {
                    throw NSError(domain: "ProxyManager", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to import Firefly CA certificate into Wine prefix."])
                }
                privateServerCertRegPath = certPath
            }

            // ═══════════════════════════════════════════
            // PHASE 1: Pre-Launch Setup (Registry)
            // ═══════════════════════════════════════════

            // 1b. Set Wine properties (RetinaMode, LeftCommandIsCtrl)
            launchLog.info("[Phase 1] Setting Wine props (retina=\(config.retinaMode), leftCmd=\(config.leftCommandIsCtrl))")
            try await wineManager.setProps(
                retinaMode: config.retinaMode,
                leftCommandIsCtrl: config.leftCommandIsCtrl,
                prefix: prefix
            )

            // 1c. Set NV extension for HSR with DXMT
            if type == .honkaiStarRail && useDXMT {
                launchLog.info("[Phase 1] Setting NV extension for HSR...")
                try await wineManager.setNVExtension(prefix: prefix)
            }

            // 1d. Apply HDR registry if enabled
            if config.enableHDR {
                let hdrData = RegistryManager.generateHDRRegistry(gameType: type, enable: true)
                hdrRegPath = try await RegistryManager.writeAndApply(
                    data: hdrData,
                    fileName: "hdr_\(type.rawValue).reg",
                    wineManager: wineManager,
                    prefix: prefix
                )
            }

            // 1c. Apply custom resolution registry if enabled
            if config.customResolution {
                let resData = RegistryManager.generateResolutionRegistry(
                    gameType: type,
                    width: config.resolutionWidth,
                    height: config.resolutionHeight,
                    fullscreen: false
                )
                resRegPath = try await RegistryManager.writeAndApply(
                    data: resData,
                    fileName: "resolution_\(type.rawValue).reg",
                    wineManager: wineManager,
                    prefix: prefix
                )
            }

            // 1e. Apply proxy registry settings
            let isProxyEnabled = config.usePrivateServer || config.proxyEnabled
            let targetProxyHost = config.usePrivateServer ? "127.0.0.1:\(freePort)" : config.proxyHost
            launchLog.info("[Phase 1] Configuring proxy registry (enabled=\(isProxyEnabled), host=\(targetProxyHost))...")
            let proxyData = RegistryManager.generateProxyRegistry(enable: isProxyEnabled, proxyHost: targetProxyHost)
            proxyRegPath = try await RegistryManager.writeAndApply(
                data: proxyData,
                fileName: "proxy_\(type.rawValue).reg",
                wineManager: wineManager,
                prefix: prefix
            )

            // 1f. Import macOS trusted certificates if proxy is enabled
            if isProxyEnabled {
                launchLog.info("[Phase 1] Importing macOS Keychain certificates into Wine...")
                certRegPath = try await RegistryManager.importMacCertificates(wineManager: wineManager, prefix: prefix)
            }

            // Wait for wineserver off before patching
            launchLog.info("[Phase 1] Waiting for wineserver off...")
            try await wineManager.waitForWineServerOff(prefix: prefix)
            launchLog.info("[Phase 1] Complete")

            // ═══════════════════════════════════════════
            // PHASE 2: Patching
            // ═══════════════════════════════════════════

            // 2a. Place DXMT DLLs (always place if enabled)
            if useDXMT {
                launchLog.info("[Phase 2] Placing DXMT DLLs (version: \(config.installedDXMTVersion ?? DXMTManager.currentDXMTVersion))...")
                try await DXMTManager.ensureDXMTAvailable()
                try DXMTManager.placeDXMTDLLs(
                    gameDir: installDir,
                    winePrefix: prefix,
                    installedVersion: config.installedDXMTVersion,
                    gameType: type
                )
                launchLog.info("[Phase 2] DXMT DLLs placed")
            }

            // 2b. Ensure jadeite is available for HSR
            if JadeiteManager.requiresJadeite(for: type) {
                launchLog.info("[Phase 2] Ensuring jadeite available...")
                try await JadeiteManager.ensureJadeiteAvailable()
                launchLog.info("[Phase 2] Jadeite ready at \(JadeiteManager.jadeiteExe)")
            }

            // 2c. Remove crash reporters and vulkan-1.dll
            let filesToRemove = Self.filesToRemove(for: type)
            for file in filesToRemove {
                let filePath = installDir + "/" + file
                let bakPath = filePath + ".bak"
                if FileManager.default.fileExists(atPath: filePath) {
                    if !FileManager.default.fileExists(atPath: bakPath) {
                        try? FileManager.default.moveItem(atPath: filePath, toPath: bakPath)
                        launchLog.info("[Phase 2] Removed: \(file)")
                    }
                }
            }

            // 2d. Place Steam emulation DLLs for Genshin
            // HSR and ZZZ do NOT use steam emulation
            if type == .genshinImpact && config.useSteamPatch {
                let system32 = prefix + "/drive_c/windows/system32"
                let syswow64 = prefix + "/drive_c/windows/syswow64"
                let sidecarDir = WineManager.sidecarPath + "/protonextras"
                let fm = FileManager.default

                if fm.fileExists(atPath: sidecarDir) {
                    let steamFiles: [(src: String, dst: String)] = [
                        ("steam64.exe", system32 + "/steam.exe"),
                        ("steam32.exe", syswow64 + "/steam.exe"),
                        ("lsteamclient64.dll", system32 + "/lsteamclient.dll"),
                        ("lsteamclient32.dll", syswow64 + "/lsteamclient.dll"),
                    ]
                    for (src, dst) in steamFiles {
                        let srcPath = sidecarDir + "/" + src
                        if fm.fileExists(atPath: srcPath) {
                            if fm.fileExists(atPath: dst) { try? fm.removeItem(atPath: dst) }
                            try? fm.copyItem(atPath: srcPath, toPath: dst)
                            launchLog.info("[Phase 2] Placed steam DLL: \(src)")
                        }
                    }
                } else {
                    launchLog.info("[Phase 2] ⚠️ Steam sidecar not found at \(sidecarDir), skipping steam emulation")
                }
            }

            launchLog.info("[Phase 2] Complete")

            // ═══════════════════════════════════════════
            // PHASE 3: Game Execution
            // ═══════════════════════════════════════════

            // 3a. Generate config.bat
            // Write config.bat in the data directory, NOT in the game directory.
            // Writing into the game folder can trigger anti-cheat.
            let batchScript = generateLaunchBatch(
                gameDir: installDir,
                executable: type.executable,
                type: type
            )
            batchPath = WineManager.basePath + "/config.bat"
            try batchScript.write(toFile: batchPath!, atomically: true, encoding: .utf8)

            launchLog.info("[Phase 3] Batch script written to \(batchPath!):")
            launchLog.info("--- config.bat ---")
            for line in batchScript.split(separator: "\n", omittingEmptySubsequences: false) {
                launchLog.info("  \(line)")
            }
            launchLog.info("--- end ---")

            // 3b. Build environment variables
            var env: [String: String] = [:]
            let baseDir = WineManager.basePath

            // Metal HUD
            if config.metalHUD {
                env["MTL_HUD_ENABLED"] = "1"
            }

            // Disable Metal validation layer — Xcode enables MTLDebugDevice by default
            // which causes MTLStorageModeShared assertions on non-Apple GPUs.
            env["MTL_DEBUG_LAYER"] = "0"
            env["MTL_SHADER_VALIDATION"] = "0"

            // Env is determined by wine.attributes.renderBackend
            // useDXMT = config.enableDXMT && renderBackend == "dxmt"
            if useDXMT {
                // DXMT mode
                env["WINEDLLOVERRIDES"] = ""
                env["WINEMSYNC"] = "1"
                env["DXMT_LOG_PATH"] = baseDir
                env["GST_PLUGIN_FEATURE_RANK"] = "atdec:MAX,avdec_h264:MAX"

                // Ensure dxmt.conf exists
                let confPath = baseDir + "/dxmt.conf"
                if !FileManager.default.fileExists(atPath: confPath) {
                    FileManager.default.createFile(atPath: confPath, contents: nil)
                }
                env["DXMT_CONFIG_FILE"] = confPath

                // Game-specific DXMT config
                if type == .honkaiStarRail {
                    env["DXMT_CONFIG"] = "d3d11.preferredMaxFrameRate=60;dxgi.customVendorId=10de;dxgi.customDeviceId=2684"
                    env["DXMT_ENABLE_NVEXT"] = "1"
                } else if type == .genshinImpact {
                    env["DXMT_CONFIG"] = "d3d11.preferredMaxFrameRate=60;"
                }
            } else {
                // Non-DXMT mode
                env["WINEESYNC"] = "1"
            }

            // WINEMSYNC (if not already set by DXMT block)
            if config.winemsync && env["WINEMSYNC"] == nil {
                env["WINEMSYNC"] = "1"
            }

            // Proxy
            if config.usePrivateServer {
                env["HTTP_PROXY"] = "127.0.0.1:\(freePort)"
                env["HTTPS_PROXY"] = "127.0.0.1:\(freePort)"
            } else if config.proxyEnabled && !config.proxyHost.isEmpty {
                env["HTTP_PROXY"] = config.proxyHost
                env["HTTPS_PROXY"] = config.proxyHost
            }

            // GStreamer (if not already set)
            if env["GST_PLUGIN_FEATURE_RANK"] == nil {
                env["GST_PLUGIN_FEATURE_RANK"] = "atdec:MAX,avdec_h264:MAX"
            }

            // 3c. Apply network blocking if configured
            if config.blockNetwork {
                launchLog.info("[Phase 3] Applying network blocking...")
                try await applyNetworkBlocking(for: type)
            }

            // 3d. Setup logging
            let logsDir = WineManager.logsPath
            try FileManager.default.createDirectory(atPath: logsDir, withIntermediateDirectories: true)
            let logFile = logsDir + "/\(type.rawValue)_\(Int(Date().timeIntervalSince1970)).log"

            // Log all env vars
            launchLog.info("[Phase 3] Environment variables:")
            for (key, value) in env.sorted(by: { $0.key < $1.key }) {
                launchLog.info("  \(key)=\(value)")
            }
            launchLog.info("[Phase 3] Wine log file: \(logFile)")
            launchLog.info("[Phase 3] Executing wine \(batchPath!)...")

            // 3e. Execute via Wine (cmd /c config.bat)
            // If steamPatch is enabled for Genshin, use steam.exe as launcher
            let winBatchPath = wineManager.toWinePath(batchPath!)
            let winExePath = wineManager.toWinePath(installDir + "/" + type.executable)
            let process: Process
            if config.useSteamPatch && type == .genshinImpact {
                // Launch via steam.exe
                process = try await wineManager.launchGame(
                    executable: "C:\\windows\\system32\\steam.exe",
                    arguments: [winExePath],
                    workingDirectory: installDir,
                    environment: env,
                    logFile: logFile,
                    prefix: prefix
                )
            } else {
                process = try await wineManager.launchGame(
                    executable: winBatchPath,
                    workingDirectory: installDir,
                    environment: env,
                    logFile: logFile,
                    prefix: prefix
                )
            }

            // Wait for game to exit — non-blocking, UI remains responsive
            let exitCode = try await ProcessRunner.run(process) { p in
                Task { @MainActor in self.gameStates[type] = .running }
                launchLog.info("[Phase 3] Game process started (PID: \(p.processIdentifier))")
            }
            
            launchLog.info("[Phase 3] Game exited with code: \(exitCode)")

            // Print last 50 lines of Wine log
            if let logData = FileManager.default.contents(atPath: logFile),
               let logContent = String(data: logData, encoding: .utf8) {
                let lines = logContent.split(separator: "\n", omittingEmptySubsequences: false)
                let tail = lines.suffix(50)
                launchLog.info("[Wine Log] Last \(tail.count) lines of \(logFile):")
                for line in tail {
                    launchLog.info("  \(line)")
                }
            }

            // Wait for wineserver off
            launchLog.info("[Phase 4] Waiting for wineserver off...")
            try? await wineManager.waitForWineServerOff(prefix: prefix)

            // ═══════════════════════════════════════════
            // PHASE 4: Post-Launch Cleanup
            // ═══════════════════════════════════════════

            // 4a. Revert HDR registry
            if let path = hdrRegPath {
                RegistryManager.revertRegistryFile(path: path)
                hdrRegPath = nil
            }

            // 4b. Revert resolution registry
            if let path = resRegPath {
                RegistryManager.revertRegistryFile(path: path)
                resRegPath = nil
            }

            // Revert proxy registry temp file
            if let path = proxyRegPath {
                RegistryManager.revertRegistryFile(path: path)
                proxyRegPath = nil
            }

            // Revert cert registry temp file
            if let path = certRegPath {
                RegistryManager.revertRegistryFile(path: path)
                certRegPath = nil
            }

            // 4c. Restore removed files (crash reporters, vulkan-1.dll)
            let filesToRestore = Self.filesToRemove(for: type)
            for file in filesToRestore {
                let filePath = installDir + "/" + file
                let bakPath = filePath + ".bak"
                if FileManager.default.fileExists(atPath: bakPath) {
                    if FileManager.default.fileExists(atPath: filePath) {
                        try? FileManager.default.removeItem(atPath: filePath)
                    }
                    try? FileManager.default.moveItem(atPath: bakPath, toPath: filePath)
                }
            }

            // 4d. Revert DXMT DLLs
            if useDXMT {
                try? DXMTManager.revertDXMTDLLs(
                    winePrefix: prefix,
                    installedVersion: config.installedDXMTVersion,
                    gameType: type
                )
            }

            // 4f. Clean up batch script
            if let path = batchPath {
                try? FileManager.default.removeItem(atPath: path)
                batchPath = nil
            }

            // 4g. Terminate Private Server proxy
            if activeProxyProcess != nil {
                launchLog.info("[Phase 4] Terminating Private Server proxy...")
                activeProxyProcess?.terminate()
                activeProxyProcess = nil
            }
            if let path = privateServerCertRegPath {
                RegistryManager.revertRegistryFile(path: path)
                privateServerCertRegPath = nil
            }

            launchLog.info("[Phase 4] Cleanup complete")
            launchLog.info("════════════════════════════════════════")
            await MainActor.run { gameStates[type] = .ready }
        } catch {
            print("[LaunchGame] ❌ ERROR: \(error.localizedDescription)")
            
            // Clean up proxy process
            if activeProxyProcess != nil {
                activeProxyProcess?.terminate()
                activeProxyProcess = nil
            }
            
            // Revert registry files
            if let path = privateServerCertRegPath { RegistryManager.revertRegistryFile(path: path) }
            if let path = hdrRegPath { RegistryManager.revertRegistryFile(path: path) }
            if let path = resRegPath { RegistryManager.revertRegistryFile(path: path) }
            if let path = proxyRegPath { RegistryManager.revertRegistryFile(path: path) }
            if let path = certRegPath { RegistryManager.revertRegistryFile(path: path) }
            
            // Clean up batch file
            if let path = batchPath {
                try? FileManager.default.removeItem(atPath: path)
            }
            
            // Restore removed crash files
            let filesToRestore = Self.filesToRemove(for: type)
            for file in filesToRestore {
                let filePath = installDir + "/" + file
                let bakPath = filePath + ".bak"
                if FileManager.default.fileExists(atPath: bakPath) {
                    if FileManager.default.fileExists(atPath: filePath) {
                        try? FileManager.default.removeItem(atPath: filePath)
                    }
                    try? FileManager.default.moveItem(atPath: bakPath, toPath: filePath)
                }
            }
            
            // Revert DXMT DLLs
            if useDXMT {
                try? DXMTManager.revertDXMTDLLs(
                    winePrefix: prefix,
                    installedVersion: config.installedDXMTVersion,
                    gameType: type
                )
            }
            
            await MainActor.run {
                reportError(error.localizedDescription, for: type)
            }
        }
    }

    // MARK: - Batch Script Generation

    /// Generate batch script matching target format.
    /// Uses JS template literals which produce \n line endings — Wine's cmd.exe handles both.
    private func generateLaunchBatch(gameDir: String, executable: String, type: GameType) -> String {
        let winGameDir = wineManager.toWinePath(gameDir)
        let config = settings.config(for: type)

        if JadeiteManager.requiresJadeite(for: type) {
            // HSR: use jadeite wrapper (no HoYoKProtect copy)
            let winJadeitePath = wineManager.toWinePath(JadeiteManager.jadeiteExe)
            let winExePath = wineManager.toWinePath(gameDir + "/" + executable)
            return "@echo off\ncd \"%~dp0\"\ncd /d \"\(winGameDir)\"\n\"\(winJadeitePath)\" \"\(winExePath)\" -- -disable-gpu-skinning"
        } else if type == .zenlessZoneZero {
            // ZZZ: copy HoYoKProtect.sys + resolution as CLI args
            let protectSrc = wineManager.toWinePath(gameDir + "/HoYoKProtect.sys")
            var args = ""
            if config.customResolution {
                args = " -screen-width \(config.resolutionWidth) -screen-height \(config.resolutionHeight) -screen-fullscreen 0"
            }
            return "@echo off\ncd \"%~dp0\"\ncopy \"\(protectSrc)\" \"%WINDIR%\\system32\\\"\ncd /d \"\(winGameDir)\"\n\"\(wineManager.toWinePath(gameDir + "/" + executable))\"\(args)"
        } else {
            // Genshin: copy HoYoKProtect.sys + cloud platform args
            let protectSrc = wineManager.toWinePath(gameDir + "/HoYoKProtect.sys")
            return "@echo off\ncd \"%~dp0\"\ncopy \"\(protectSrc)\" \"%WINDIR%\\system32\\\"\ncd /d \"\(winGameDir)\"\n\"\(wineManager.toWinePath(gameDir + "/" + executable))\" -platform_type CLOUD_THIRD_PARTY_PC -is_cloud 1"
        }
    }


    // MARK: - Files to Remove per game

    private static func filesToRemove(for type: GameType) -> [String] {
        switch type {
        case .genshinImpact:
            // Files to remove for Genshin
            return [
                "GenshinImpact_Data/upload_crash.exe",
                "GenshinImpact_Data/Plugins/crashreport.exe",
                "GenshinImpact_Data/Plugins/vulkan-1.dll",
            ]
        case .honkaiStarRail:
            // Files to remove for Honkai Star Rail
            return [
                "StarRail_Data/upload_crash.exe",
                "StarRail_Data/Plugins/crashreport.exe",
                "StarRail_Data/Plugins/vulkan-1.dll",
            ]
        case .zenlessZoneZero:
            // Files to remove for Zenless Zone Zero
            return [
                "ZenlessZoneZero_Data/upload_crash.exe",
                "ZenlessZoneZero_Data/Plugins/crashreport.exe",
                "ZenlessZoneZero_Data/Plugins/vulkan-1.dll",
            ]
        }
    }

    // MARK: - Network Blocking (/etc/hosts manipulation via osascript)
    //
    // Blocks the game's dispatch server domain during launch.
    // This prevents the anti-cheat from phoning home while patched binaries load.
    // The block auto-removes after a delay via a background shell script.
    //
    // Domains:
    //   GI OS:  dispatchosglobal.yuanshen.com       (sleep 10)
    //   HSR OS: globaldp-prod-os01.starrails.com     (sleep 15)
    //   ZZZ OS: globaldp-prod-os01.zenlesszonezero.com (sleep 20)

    private func applyNetworkBlocking(for type: GameType) async throws {
        // Block URL and sleep duration per game
        let blockUrl: String
        let sleepSeconds: Int
        switch type {
        case .genshinImpact:
            blockUrl = "dispatchosglobal.yuanshen.com"
            sleepSeconds = 10
        case .honkaiStarRail:
            blockUrl = "globaldp-prod-os01.starrails.com"
            sleepSeconds = 15
        case .zenlessZoneZero:
            blockUrl = "globaldp-prod-os01.zenlesszonezero.com"
            sleepSeconds = 20
        }

        // Setup temporary script path:
        let tmpScriptPath = "/tmp/launcher_network_block_script.sh"

        let commands = [
            "#!/bin/sh",
            "",
            "HOSTS_FILE=\"/etc/hosts\"",
            "ENTRY=\"0.0.0.0 \(blockUrl)\"",
            "PAD_START=\"# Temporarily Added by Launcher\"",
            "PAD_END=\"# End of section\"",
            "",
            "if ! grep -qF \"$ENTRY\" \"$HOSTS_FILE\"; then",
            "sudo bash -c \"echo -e '$PAD_START\\n$ENTRY\\n$PAD_END' >> '/etc/hosts'\"",
            "fi",
            "sleep \(sleepSeconds)",
            "sudo sed -i.bak \"/$PAD_START/,/$PAD_END/d\" \"$HOSTS_FILE\"",
            "",
            "rm \(tmpScriptPath)",
        ]

        // Write script file
        try commands.joined(separator: "\n").write(
            toFile: tmpScriptPath, atomically: true, encoding: .utf8
        )

        // Execute via osascript with admin privileges, backgrounded
        let osascript = "do shell script \"source \(tmpScriptPath) > /dev/null 2>&1 &\" with administrator privileges"
        try await ProcessRunner.run("/usr/bin/osascript", arguments: ["-e", osascript])
    }

    // MARK: - Fix Webview

    private func fixWebview(type: GameType, prefix: String) async throws {
        let key: String
        switch type {
        case .honkaiStarRail:
            key = "HKEY_CURRENT_USER\\Software\\Cognosphere\\Star Rail"
        case .zenlessZoneZero:
            key = "HKEY_CURRENT_USER\\Software\\miHoYo\\ZenlessZoneZero"
        default:
            return
        }

        // Build registry to delete webview render method keys
        var regLines = [
            "Windows Registry Editor Version 5.00",
            "",
            "[\(key)]",
            "\"MIHOYOSDK_WEBVIEW_RENDER_METHOD_h1573598267\"=-"
        ]

        // Query existing registry for HOYO_WEBVIEW_RENDER_METHOD_ABTEST_ keys
        let queryResult = try? await wineManager.exec(
            program: "reg",
            arguments: ["query", key],
            prefix: prefix,
            logFile: WineManager.basePath + "/fix_webview.log"
        )

        if queryResult == 0 {
            let logPath = WineManager.basePath + "/fix_webview.log"
            if let logData = FileManager.default.contents(atPath: logPath),
               let output = String(data: logData, encoding: .utf8) {
                for line in output.split(separator: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("HOYO_WEBVIEW_RENDER_METHOD_ABTEST_") {
                        let abtest = trimmed.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
                        if !abtest.isEmpty {
                            regLines.append("\"\(abtest)\"=-")
                        }
                    }
                }
            }
            try? FileManager.default.removeItem(atPath: logPath)
        }

        // Write and import the reg file
        let regContent = regLines.joined(separator: "\r\n")
        let regPath = WineManager.basePath + "/fix_webview.reg"

        // Write as UTF-16LE (Windows registry format)
        if let data = regContent.data(using: .utf16LittleEndian) {
            // Add BOM
            var bom = Data([0xFF, 0xFE])
            bom.append(data)
            try bom.write(to: URL(fileURLWithPath: regPath))
        }

        _ = try? await wineManager.exec(
            program: "reg",
            arguments: ["import", wineManager.toWinePath(regPath)],
            prefix: prefix
        )

        try? FileManager.default.removeItem(atPath: regPath)
    }

    // MARK: - Check Integrity

    func checkIntegrity(for type: GameType) async {
        let config = settings.config(for: type)
        guard let dir = config.installDirectory else { return }

        await MainActor.run {
            gameStates[type] = .installing(progress: 0, status: "Checking integrity...")
        }

        // This would normally fetch a file manifest from the server
        // For now, verify basic game files exist
        let fm = FileManager.default
        let requiredFiles = [type.executable, type.dataDir]
        var allPresent = true
        for file in requiredFiles {
            if !fm.fileExists(atPath: dir + "/" + file) {
                allPresent = false
                break
            }
        }

        await MainActor.run {
            if allPresent {
                gameStates[type] = .ready
            } else {
                reportError("Game files corrupted or missing", for: type)
            }
        }
    }

    // MARK: - Predownload

    func predownloadUpdate(for type: GameType) async {
        guard let gameInfo = games[type] else { return }

        do {
            let manifest = try await api.fetchLatestVersion(for: gameInfo)
            guard let predownload = manifest.pre_download,
                  let major = predownload.major,
                  let pkg = major.game_pkgs.first,
                  let url = URL(string: pkg.url) else { return }

            let tempDir = WineManager.basePath + "/predownload/\(type.rawValue)"
            try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)

            downloadManager.download(
                url: url,
                to: URL(fileURLWithPath: tempDir + "/" + url.lastPathComponent),
                id: "predownload_\(type.rawValue)",
                gameType: type,
                onProgress: { _ in },
                onComplete: { [weak self] result in
                    if case .success = result {
                        self?.settings.updateConfig(for: type) { config in
                            config.predownloadedAll = true
                        }
                        self?.settings.save()
                    }
                }
            )
        } catch {
            print("Predownload failed: \(error)")
        }
    }
}

// MARK: - WineInstallProgress Extension

extension WineInstallProgress {
    var downloadProgress: Double {
        switch self {
        case .downloading(let p): return p
        default: return 0
        }
    }
}

// MARK: - Launch Logger

private struct LaunchLogger {
    let gameType: GameType
    let startTime = Date()

    func info(_ message: String) {
        let elapsed = String(format: "%.1f", Date().timeIntervalSince(startTime))
        print("[Launch/\(gameType.shortName) +\(elapsed)s] \(message)")
    }

    func warning(_ message: String) {
        info("[WARNING] \(message)")
    }

    func error(_ message: String) {
        info("[ERROR] \(message)")
    }
}
