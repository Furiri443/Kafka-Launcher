import Foundation

// MARK: - Wine Manager

@Observable
class WineManager {
    var status: WineStatus = .notChecked
    var installProgress: WineInstallProgress?

    /// When the user selects "Custom" mode, set this path before calling checkWineAvailability()
    var customWinePath: String = ""

    private let fileManager = FileManager.default

    // MARK: - Constants

    static let basePath = NSHomeDirectory() + "/.kafka-launcher"
    static let winePath = basePath + "/wine"
    static let defaultPrefixPath = basePath + "/wineprefix"
    static let logsPath = basePath + "/logs"
    static let dxmtPath = basePath + "/dxmt"
    static let sidecarPath = basePath + "/sidecar"
    static let protonExtrasFiles = [
        "steam64.exe",
        "steam32.exe",
        "lsteamclient64.dll",
        "lsteamclient32.dll",
    ]
    private static let devProjectRoot = ((#filePath as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent

    // MARK: - Wine Distributions

    static let distributions: [WineDistribution] = [
        // ── DXMT-compatible (Experimental/Signed) ──
        WineDistribution(
            id: "11.0-1-crossover-signed-experimental",
            displayName: "Wine 11.0-1 Crossover (signed, experimental)",
            remoteUrl: "https://github.com/yaagl/anime-game-wine/releases/download/wine-crossover-11.0-1-signed/wine-crossover-11.0-1-osx64-signed.tar.xz",
            format: .tarXz,
            winePath: "wine",
            renderBackend: "dxmt"
        ),
        WineDistribution(
            id: "11.8-dxmt-signed-experimental",
            displayName: "Wine 11.8 DXMT (signed, experimental)",
            remoteUrl: "https://github.com/yaagl/anime-game-wine/releases/download/wine-11.8-signed/wine-devel-11.8-osx64-signed.tar.xz",
            format: .tarXz,
            winePath: "wine",
            renderBackend: "dxmt"
        ),
        WineDistribution(
            id: "11.4-dxmt-signed",
            displayName: "Wine 11.4 DXMT (signed)",
            remoteUrl: "https://github.com/dawn-winery/dawn-signed/releases/download/wine-gcenx-11.4-osx64/wine-devel-11.4-osx64-signed.tar.xz",
            format: .tarXz,
            winePath: "wine-devel-11.4-osx64-signed/Contents/Resources/wine",
            renderBackend: "dxmt"
        ),
        WineDistribution(
            id: "11.0-dxmt-signed",
            displayName: "Wine 11.0 DXMT (signed)",
            remoteUrl: "https://github.com/dawn-winery/dawn-signed/releases/download/wine-stable-gcenx-11.0-osx64/wine-stable-11.0-osx64-signed.tar.xz",
            format: .tarXz,
            winePath: "Wine Stable.app/Contents/Resources/wine",
            renderBackend: "dxmt"
        ),
        // ── DXMT-compatible (3Shain builds) ──
        WineDistribution(
            id: "9.9-dxmt",
            displayName: "Wine 9.9 DXMT (3Shain, recommended)",
            remoteUrl: "https://github.com/3Shain/wine/releases/download/v9.9-mingw/wine.tar.gz",
            format: .tarGz,
            winePath: nil,
            renderBackend: "dxmt"
        ),
        // ── Signed builds (Gcenx/dawn-winery — NO DXMT, Vulkan only) ──
        WineDistribution(
            id: "11.4-signed",
            displayName: "Wine 11.4 Signed (no DXMT, Vulkan)",
            remoteUrl: "https://github.com/dawn-winery/dawn-signed/releases/download/wine-gcenx-11.4-osx64/wine-devel-11.4-osx64-signed.tar.xz",
            format: .tarXz,
            winePath: "wine-devel-11.4-osx64-signed/Contents/Resources/wine",
            renderBackend: "dxvk"
        ),
        WineDistribution(
            id: "11.0-signed",
            displayName: "Wine 11.0 Signed (no DXMT, Vulkan)",
            remoteUrl: "https://github.com/dawn-winery/dawn-signed/releases/download/wine-stable-gcenx-11.0-osx64/wine-stable-11.0-osx64-signed.tar.xz",
            format: .tarXz,
            winePath: "Wine Stable.app/Contents/Resources/wine",
            renderBackend: "dxvk"
        ),
        WineDistribution(
            id: "wine-devel-11.6-gcenx",
            displayName: "Wine 11.6 Devel (Gcenx, no DXMT)",
            remoteUrl: "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.6/wine-devel-11.6-osx64.tar.xz",
            format: .tarXz,
            winePath: "Wine Devel.app/Contents/Resources/wine",
            renderBackend: "dxvk"
        ),
    ]

    static let defaultDistribution = distributions.first(where: { $0.id == "9.9-dxmt" }) ?? distributions[0]

    // MARK: - Persistent Wine State Keys

    private static let kWineState = "wine_state"
    private static let kWineTag = "wine_tag"
    private static let kWineUpdateTag = "wine_update_tag"
    private static let kWineNetBIOSName = "wine_netbiosname"
    private static let kInstalledDXMTVersion = "installed_dxmt_version"

    // MARK: - Check Wine Status

    func checkWineAvailability() -> WineStatus {
        // 1. Custom path takes priority if set
        if !customWinePath.isEmpty {
            let wine64 = customWinePath + "/bin/wine64"
            let wine   = customWinePath + "/bin/wine"
            if fileManager.isExecutableFile(atPath: wine64) || fileManager.isExecutableFile(atPath: wine) {
                status = .customWine(path: customWinePath)
                return status
            } else {
                // Custom path set but invalid — report error
                status = .customWineInvalid(path: customWinePath)
                return status
            }
        }

        let defaults = UserDefaults.standard
        let wineState = defaults.string(forKey: Self.kWineState)

        if wineState == "update" {
            if let updateTag = defaults.string(forKey: Self.kWineUpdateTag),
               let distro = Self.distributions.first(where: { $0.id == updateTag }) {
                status = .needsUpdate(distro)
                return status
            }
        }

        if let currentTag = defaults.string(forKey: Self.kWineTag),
           let distro = Self.distributions.first(where: { $0.id == currentTag }) {
            // Verify wine binary exists (wine64 or wine)
            let wineBin = Self.winePath + "/bin/wine64"
            let wineBinAlt = Self.winePath + "/bin/wine"
            if fileManager.isExecutableFile(atPath: wineBin) || fileManager.isExecutableFile(atPath: wineBinAlt) {
                status = .ready(distro)
                return status
            }
        }

        // Also check system Wine/GPTK/CrossOver
        if let systemPath = findSystemWine() {
            status = .systemWine(path: systemPath)
            return status
        }

        status = .notInstalled(Self.defaultDistribution)
        return status
    }

    // MARK: - Wine Installation

    func installWine(distribution: WineDistribution? = nil, onProgress: ((WineInstallProgress) -> Void)? = nil) async throws {
        let distro = distribution ?? Self.defaultDistribution
        let defaults = UserDefaults.standard

        // 1. Clean existing wine directory
        let progress1 = WineInstallProgress.preparing
        installProgress = progress1
        onProgress?(progress1)

        if fileManager.fileExists(atPath: Self.winePath) {
            // Use rm -rf instead of FileManager.removeItem because signed Wine
            // builds have code-signing xattrs that prevent normal deletion
            try await rmrf(Self.winePath)
        }
        try fileManager.createDirectory(atPath: Self.winePath, withIntermediateDirectories: true)

        // 2. Download Wine archive
        let archiveName = distro.format == .tarXz ? "wine.tar.xz" : "wine.tar.gz"
        let archivePath = Self.basePath + "/" + archiveName

        guard let url = URL(string: distro.remoteUrl) else {
            throw WineError.invalidURL(distro.remoteUrl)
        }

        let progressDownloading = WineInstallProgress.downloading(0)
        installProgress = progressDownloading
        onProgress?(progressDownloading)

        try await downloadFile(from: url, to: archivePath) { progress in
            let p = WineInstallProgress.downloading(progress)
            Task { @MainActor in
                self.installProgress = p
            }
            onProgress?(p)
        }

        // 3. Extract archive
        let progressExtracting = WineInstallProgress.extracting(0)
        installProgress = progressExtracting
        onProgress?(progressExtracting)

        try await extractArchive(archivePath, to: Self.winePath, winePath: distro.winePath) { progress in
            let p = WineInstallProgress.extracting(progress)
            Task { @MainActor in
                self.installProgress = p
            }
            onProgress?(p)
        }

        // Clean up archive
        try? fileManager.removeItem(atPath: archivePath)

        // 4. Remove macOS quarantine attribute & set executable permissions
        let progressQuarantine = WineInstallProgress.removingQuarantine
        installProgress = progressQuarantine
        onProgress?(progressQuarantine)

        try await removeQuarantineAttribute(at: Self.winePath)

        // Ensure wine binaries are executable
        let binDir = Self.winePath + "/bin"
        let libDir = Self.winePath + "/lib"
        try? await ProcessRunner.run("/bin/chmod", arguments: ["-R", "+x", binDir, libDir])

        // 5. Initialize Wine prefix
        let progressInit = WineInstallProgress.initializingPrefix
        installProgress = progressInit
        onProgress?(progressInit)

        try await initializeWinePrefix()

        // 6. Store state
        defaults.set("ready", forKey: Self.kWineState)
        defaults.set(distro.id, forKey: Self.kWineTag)
        defaults.removeObject(forKey: Self.kWineUpdateTag)
        defaults.set(generateNetBIOSName(), forKey: Self.kWineNetBIOSName)

        let progressComplete = WineInstallProgress.complete
        installProgress = progressComplete
        onProgress?(progressComplete)

        status = .ready(distro)
    }

    // MARK: - Wine Prefix Initialization (wineboot -u, winecfg -v win10)

    func recreateWinePrefix(prefixPath: String? = nil) async throws {
        let prefix = prefixPath ?? Self.defaultPrefixPath
        
        // Ensure wineserver is off before deleting
        try? await waitForWineServerOff(prefix: prefix)
        
        if fileManager.fileExists(atPath: prefix) {
            try await rmrf(prefix)
        }
        
        try await initializeWinePrefix(prefixPath: prefix)
    }

    func initializeWinePrefix(prefixPath: String? = nil) async throws {
        let prefix = prefixPath ?? Self.defaultPrefixPath

        if !fileManager.fileExists(atPath: prefix) {
            try fileManager.createDirectory(atPath: prefix, withIntermediateDirectories: true)
        }

        let wineBin = getWineBinary()
        guard fileManager.isExecutableFile(atPath: wineBin) else {
            throw WineError.wineNotFound
        }

        let baseEnv = wineEnvironment(prefix: prefix)

        // wineboot -u (initialize/update prefix)
        try await runWineProcess(wineBin, arguments: ["wineboot", "-u"], environment: baseEnv)

        // winecfg -v win10 (set Windows 10 compatibility)
        try await runWineProcess(wineBin, arguments: ["winecfg", "-v", "win10"], environment: baseEnv)

        // Wait for wineserver to finish
        try await waitForWineServerOff(prefix: prefix)
    }

    // MARK: - Media Foundation DLLs

    static let mediaFoundationDLLs = [
        "colorcnv", "mf", "mferror", "mfplat", "mfplay",
        "mfreadwrite", "msmpeg2adec", "msmpeg2vdec", "sqmapi"
    ]

    static let mediaFoundationServiceDLLs = ["colorcnv", "msmpeg2adec", "msmpeg2vdec"]

    func installMediaFoundation(prefix: String? = nil) async throws {
        let pfx = prefix ?? Self.defaultPrefixPath
        let system32 = pfx + "/drive_c/windows/system32"
        let wineBin = getWineBinary()
        let env = wineEnvironment(prefix: pfx)

        let baseURL = "https://github.com/Ultimator14/mf-install/raw/master/system32"

        for dll in Self.mediaFoundationDLLs {
            let dllName = dll + ".dll"
            let destPath = system32 + "/" + dllName
            let tempPath = destPath + ".downloading"

            guard let url = URL(string: baseURL + "/" + dllName) else { continue }

            try await downloadFile(from: url, to: tempPath)

            // Move to final location
            if fileManager.fileExists(atPath: destPath) {
                try fileManager.removeItem(atPath: destPath)
            }
            try fileManager.moveItem(atPath: tempPath, toPath: destPath)

            // Register as native override
            try await runWineProcess(wineBin, arguments: [
                "reg", "add", "HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides",
                "/v", dll, "/d", "native", "/f"
            ], environment: env)
        }

        // Register service DLLs
        for dll in Self.mediaFoundationServiceDLLs {
            try await runWineProcess(wineBin, arguments: [
                "regsvr32", dll + ".dll"
            ], environment: env)
        }

        try await waitForWineServerOff(prefix: pfx)
    }

    // MARK: - Game Launching

    func launchGame(
        executable: String,
        arguments: [String]? = nil,
        workingDirectory: String,
        environment: [String: String] = [:],
        logFile: String? = nil,
        prefix: String? = nil
    ) async throws -> Process {
        let wineBin = getWineBinary()
        guard fileManager.isExecutableFile(atPath: wineBin) else {
            // Fallback to system wine
            if let sysWine = findSystemWine() {
                return try await launchWithBinary(
                    sysWine, executable: executable,
                    arguments: arguments,
                    workingDirectory: workingDirectory,
                    environment: environment,
                    logFile: logFile,
                    prefix: prefix
                )
            }
            throw WineError.wineNotFound
        }

        return try await launchWithBinary(
            wineBin, executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            logFile: logFile,
            prefix: prefix
        )
    }

    private func launchWithBinary(
        _ wineBin: String,
        executable: String,
        arguments: [String]?,
        workingDirectory: String,
        environment: [String: String],
        logFile: String?,
        prefix: String?
    ) async throws -> Process {
        let pfx = prefix ?? Self.defaultPrefixPath

        let process = Process()
        process.executableURL = URL(fileURLWithPath: wineBin)
        // If custom arguments are provided (e.g. steam.exe), use them directly
        // Otherwise default to cmd /c <executable>
        if let args = arguments {
            process.arguments = [executable] + args
        } else {
            process.arguments = ["cmd", "/c", executable]
        }
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

        var env = wineEnvironment(prefix: pfx)
        env.merge(environment) { _, new in new }
        process.environment = env

        // Setup logging
        if let logPath = logFile {
            try fileManager.createDirectory(
                atPath: (logPath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            fileManager.createFile(atPath: logPath, contents: nil)
            let logHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
            process.standardOutput = logHandle
            process.standardError = logHandle
        }

        return process
    }

    // MARK: - Execute Wine Command (sync, waits for completion)

    func exec(
        program: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        prefix: String? = nil,
        logFile: String? = nil
    ) async throws -> Int32 {
        let wineBin = getWineBinary()
        let pfx = prefix ?? Self.defaultPrefixPath
        var env = wineEnvironment(prefix: pfx)
        env.merge(environment) { _, new in new }

        let args = [program] + arguments

        let process = Process()
        process.executableURL = URL(fileURLWithPath: wineBin)
        process.arguments = args
        process.environment = env

        if let logPath = logFile {
            try fileManager.createDirectory(
                atPath: (logPath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            fileManager.createFile(atPath: logPath, contents: nil)
            let logHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
            process.standardOutput = logHandle
            process.standardError = logHandle
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        return try await ProcessRunner.run(process)
    }

    // MARK: - Registry Operations

    func setProps(
        retinaMode: Bool,
        leftCommandIsCtrl: Bool,
        prefix: String? = nil
    ) async throws {
        let pfx = prefix ?? Self.defaultPrefixPath
        let wineBin = getWineBinary()
        let env = wineEnvironment(prefix: pfx)

        // RetinaMode registry
        let retinaValue = retinaMode ? "y" : "n"
        try await runWineProcess(wineBin, arguments: [
            "reg", "add", "HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver",
            "/v", "RetinaMode", "/d", retinaValue, "/f"
        ], environment: env)

        // LeftCommandIsCtrl registry
        let ctrlValue = leftCommandIsCtrl ? "y" : "n"
        try await runWineProcess(wineBin, arguments: [
            "reg", "add", "HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver",
            "/v", "LeftCommandIsCtrl", "/d", ctrlValue, "/f"
        ], environment: env)

        try await waitForWineServerOff(prefix: pfx)
    }

    // MARK: - Apply Registry File

    func applyRegistryFile(_ regFilePath: String, prefix: String? = nil) async throws {
        let pfx = prefix ?? Self.defaultPrefixPath
        let wineBin = getWineBinary()
        let env = wineEnvironment(prefix: pfx)
        let wineRegPath = toWinePath(regFilePath)

        try await ProcessRunner.runChecked(
            wineBin,
            arguments: ["reg", "import", wineRegPath],
            environment: env
        ) { code in
            WineError.registryFailed("reg import failed with exit code \(code)")
        }

        try await waitForWineServerOff(prefix: pfx)
    }

    // MARK: - NVIDIA Extension Registration

    func setNVExtension(prefix: String? = nil) async throws {
        let pfx = prefix ?? Self.defaultPrefixPath
        let wineBin = getWineBinary()
        let env = wineEnvironment(prefix: pfx)

        // Register NVIDIA extension keys at HKLM
        // These keys enable nvngx.dll (DLSS) and NV extension spoofing for HSR
        let batchLines = [
            "@echo off",
            "cd \"%~dp0\"",
            "reg add \"HKEY_LOCAL_MACHINE\\SOFTWARE\\NVIDIA Corporation\\Global\" /v \"{41FCC608-8496-4DEF-B43E-7D9BD675A6FF}\" /t REG_BINARY /d 1 /f",
            "reg add \"HKEY_LOCAL_MACHINE\\SYSTEM\\ControlSet001\\Services\\nvlddmkm\" /v \"{41FCC608-8496-4DEF-B43E-7D9BD675A6FF}\" /t REG_BINARY /d 1 /f",
            "reg add \"HKEY_LOCAL_MACHINE\\SOFTWARE\\NVIDIA Corporation\\Global\\NGXCore\" /v FullPath /t REG_SZ /d \"C:\\Windows\\System32\" /f",
        ]
        let batchContent = batchLines.joined(separator: "\r\n")
        let batchPath = Self.basePath + "/nvext_config.bat"
        try batchContent.write(toFile: batchPath, atomically: true, encoding: .utf8)

        try await runWineProcess(wineBin, arguments: [
            "cmd", "/c", toWinePath(batchPath)
        ], environment: env)

        try? FileManager.default.removeItem(atPath: batchPath)
        try await waitForWineServerOff(prefix: pfx)
    }

    // MARK: - Path Conversion

    func toWinePath(_ absPath: String) -> String {
        "Z:" + absPath.replacingOccurrences(of: "/", with: "\\")
    }

    // MARK: - Wait for Wine Server Off

    func waitForWineServerOff(prefix: String? = nil) async throws {
        let pfx = prefix ?? Self.defaultPrefixPath
        let wineserverBin = getWineServerBinary()
        guard fileManager.isExecutableFile(atPath: wineserverBin) else { return }
        try await ProcessRunner.run(
            wineserverBin,
            arguments: ["-w"],
            environment: ["WINEPREFIX": pfx]
        )
    }

    func killWineServer(prefix: String? = nil) async throws {
        let pfx = prefix ?? Self.defaultPrefixPath
        let wineserverBin = getWineServerBinary()
        guard fileManager.isExecutableFile(atPath: wineserverBin) else { return }
        try await ProcessRunner.run(
            wineserverBin,
            arguments: ["-k"],
            environment: ["WINEPREFIX": pfx]
        )
        try await waitForWineServerOff(prefix: pfx)
    }

    // MARK: - Open CMD Window

    func openCmdWindow(gameDir: String, prefix: String? = nil) async throws {
        let pfx = prefix ?? Self.defaultPrefixPath
        let wineBin = getWineBinary()

        // Disable RetinaMode so the console window isn't tiny.
        try? await runWineProcess(wineBin, arguments: [
            "reg", "add", "HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver",
            "/v", "RetinaMode", "/d", "n", "/f"
        ], environment: wineEnvironment(prefix: pfx))

        // Use a temporary .command launcher to avoid fragile AppleScript quoting.
        let commandPath = Self.basePath + "/open-wine-console.command"
        let commandContents = """
        #!/bin/zsh
        export WINEPREFIX=\(shellSingleQuoted(pfx))
        export WINEDEBUG='fixme-all,err-unwind'
        exec \(shellSingleQuoted(wineBin)) cmd /k \(shellSingleQuoted("cd /d \(toWinePath(gameDir))"))
        """
        try commandContents.write(toFile: commandPath, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: commandPath)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", commandPath]
        try process.run()
    }

    // MARK: - Open Wine Tools (winecfg / regedit)

    /// Launch a built-in Wine GUI tool (e.g. "winecfg", "regedit") detached
    /// against the given prefix. Does not wait for the tool to exit.
    func openWineTool(_ tool: String, prefix: String? = nil) async throws {
        let pfx = prefix ?? Self.defaultPrefixPath
        let wineBin = getWineBinary()
        guard fileManager.isExecutableFile(atPath: wineBin) else {
            throw WineError.wineNotFound
        }
        try? fileManager.createDirectory(atPath: pfx, withIntermediateDirectories: true)
        let env = wineEnvironment(prefix: pfx)

        // Disable RetinaMode so the tool window isn't tiny.
        try await runWineProcess(wineBin, arguments: [
            "reg", "add", "HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver",
            "/v", "RetinaMode", "/d", "n", "/f"
        ], environment: env)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: wineBin)
        process.arguments = [tool]
        process.environment = env
        try process.run()
    }


    func getWineBinary() -> String {
        // 1. Custom path
        if !customWinePath.isEmpty {
            let wine64 = customWinePath + "/bin/wine64"
            let wine   = customWinePath + "/bin/wine"
            return FileManager.default.fileExists(atPath: wine64) ? wine64 : wine
        }
        // 2. Managed path
        let wine64 = Self.winePath + "/bin/wine64"
        let wine = Self.winePath + "/bin/wine"
        return FileManager.default.fileExists(atPath: wine64) ? wine64 : wine
    }

    private func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func getWineServerBinary() -> String {
        if !customWinePath.isEmpty {
            return customWinePath + "/bin/wineserver"
        }
        return Self.winePath + "/bin/wineserver"
    }

    func wineEnvironment(prefix: String? = nil) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["WINEDEBUG"] = "fixme-all,err-unwind,+timestamp"
        env["WINEPREFIX"] = prefix ?? Self.defaultPrefixPath
        return env
    }

    private func findSystemWine() -> String? {
        let paths = [
            "/usr/local/opt/game-porting-toolkit/bin/wine64",
            "/opt/homebrew/opt/game-porting-toolkit/bin/wine64",
            "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine64",
            "/opt/homebrew/bin/wine64",
            "/usr/local/bin/wine64",
        ]
        return paths.first { fileManager.isExecutableFile(atPath: $0) }
    }

    private func generateNetBIOSName() -> String {
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        let suffix = String((0..<7).map { _ in chars.randomElement()! })
        return "DESKTOP-" + suffix
    }

    func ensureProtonExtrasAvailable() throws -> Bool {
        let fm = FileManager.default
        let destDir = Self.sidecarPath + "/protonextras"
        try fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)

        let sourceCandidates = [
            Bundle.main.resourceURL?.appendingPathComponent("sidecar/protonextras", isDirectory: true),
            URL(fileURLWithPath: Self.devProjectRoot).appendingPathComponent("sidecar/protonextras", isDirectory: true),
        ].compactMap { $0 }

        guard let sourceDir = sourceCandidates.first(where: { fm.fileExists(atPath: $0.path) }) else {
            return false
        }

        for file in Self.protonExtrasFiles {
            let srcPath = sourceDir.appendingPathComponent(file).path
            let dstPath = destDir + "/" + file

            guard fm.fileExists(atPath: srcPath) else { continue }

            let shouldCopy: Bool
            if !fm.fileExists(atPath: dstPath) {
                shouldCopy = true
            } else {
                let srcSize = (try? fm.attributesOfItem(atPath: srcPath)[.size] as? NSNumber)?.int64Value
                let dstSize = (try? fm.attributesOfItem(atPath: dstPath)[.size] as? NSNumber)?.int64Value
                shouldCopy = srcSize != dstSize
            }

            if shouldCopy {
                if fm.fileExists(atPath: dstPath) {
                    try fm.removeItem(atPath: dstPath)
                }
                try fm.copyItem(atPath: srcPath, toPath: dstPath)
            }
        }

        return true
    }

    private func downloadFile(
        from url: URL,
        to destination: String,
        onProgress: ((Double) -> Void)? = nil
    ) async throws {
        let destURL = URL(fileURLWithPath: destination)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let delegate = WineDownloadDelegate(
                destination: destURL,
                onProgress: onProgress,
                onComplete: { result in
                    switch result {
                    case .success: continuation.resume()
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
            )
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            let task = session.downloadTask(with: url)
            task.resume()
        }
    }

    private func extractArchive(_ archivePath: String, to destination: String, winePath: String? = nil, onProgress: ((Double) -> Void)? = nil) async throws {
        let fm = FileManager.default
        let ext = (archivePath as NSString).pathExtension

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        let extractFlag = (ext == "xz" || archivePath.hasSuffix(".tar.xz")) ? "xJf" : "xzf"
        process.arguments = [extractFlag, archivePath, "-C", destination]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        // Poll progress concurrently while waiting non-blocking for extraction to finish
        async let exitCode: Int32 = ProcessRunner.run(process)

        let pollTask = Task {
            while process.isRunning {
                try? await Task.sleep(for: .milliseconds(500))
                if let enumerator = fm.enumerator(atPath: destination) {
                    var count = 0
                    while enumerator.nextObject() != nil { count += 1 }
                    let progress = min(Double(count) / 8000.0, 0.99)
                    onProgress?(progress)
                }
            }
        }

        let code = try await exitCode
        pollTask.cancel()
        onProgress?(1.0)

        guard code == 0 else { throw WineError.extractionFailed }

        // If winePath is set, move nested wine dir to root
        if let winePath = winePath {
            let nestedPath = destination + "/" + winePath
            if fm.fileExists(atPath: nestedPath) {
                let tempPath = destination + "/_wine_temp"
                try fm.moveItem(atPath: nestedPath, toPath: tempPath)

                let contents = try fm.contentsOfDirectory(atPath: destination)
                for item in contents where item != "_wine_temp" {
                    try? fm.removeItem(atPath: destination + "/" + item)
                }

                let wineContents = try fm.contentsOfDirectory(atPath: tempPath)
                for item in wineContents {
                    try fm.moveItem(atPath: tempPath + "/" + item, toPath: destination + "/" + item)
                }
                try fm.removeItem(atPath: tempPath)
            }
        }
    }

    private func removeQuarantineAttribute(at path: String) async throws {
        try await ProcessRunner.run("/usr/bin/xattr", arguments: ["-dr", "com.apple.quarantine", path])
    }

    /// Force-remove directory.
    /// Signed Wine builds have code-signing xattrs that block FileManager.removeItem.
    private func rmrf(_ path: String) async throws {
        try await ProcessRunner.runChecked("/bin/rm", arguments: ["-rf", path])
    }

    private func runWineProcess(_ wineBin: String, arguments: [String], environment: [String: String]) async throws {
        try await ProcessRunner.run(wineBin, arguments: arguments, environment: environment)
    }
}

// MARK: - Wine Types

struct WineDistribution: Identifiable, Equatable {
    let id: String
    let displayName: String
    let remoteUrl: String
    let format: ArchiveFormat
    let winePath: String?
    let renderBackend: String

    enum ArchiveFormat: Equatable {
        case tarXz
        case tarGz
    }
}

enum WineStatus: Equatable {
    case notChecked
    case notInstalled(WineDistribution)
    case needsUpdate(WineDistribution)
    case ready(WineDistribution)
    case systemWine(path: String)
    case customWine(path: String)        // User-supplied folder, valid
    case customWineInvalid(path: String) // User-supplied folder, no wine binary found

    var isReady: Bool {
        switch self {
        case .ready, .systemWine, .customWine: return true
        default: return false
        }
    }

    var displayName: String {
        switch self {
        case .notChecked: return "Not Checked"
        case .notInstalled: return "Not Installed"
        case .needsUpdate(let d): return "Update Available: \(d.displayName)"
        case .ready(let d): return d.displayName
        case .systemWine(let p): return "System Wine (\(p))"
        case .customWine(let p): return "Custom: \((p as NSString).lastPathComponent)"
        case .customWineInvalid(let p): return "Invalid path: \((p as NSString).lastPathComponent)"
        }
    }
}

enum WineInstallProgress: Equatable {
    case preparing
    case downloading(Double)
    case extracting(Double)
    case removingQuarantine
    case initializingPrefix
    case installingMediaFoundation
    case complete

    var description: String {
        switch self {
        case .preparing: return "Preparing..."
        case .downloading(let p): return "Downloading Wine... \(Int(p * 100))%"
        case .extracting(let p): return "Extracting Wine... \(Int(p * 100))%"
        case .removingQuarantine: return "Removing quarantine..."
        case .initializingPrefix: return "Initializing Wine prefix..."
        case .installingMediaFoundation: return "Installing Media Foundation..."
        case .complete: return "Wine installation complete"
        }
    }
}

// MARK: - Wine Download Delegate (progress reporting)

private class WineDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let destination: URL
    let onProgress: ((Double) -> Void)?
    let onComplete: (Result<Void, Error>) -> Void
    private var completed = false

    init(destination: URL, onProgress: ((Double) -> Void)?, onComplete: @escaping (Result<Void, Error>) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
        self.onComplete = onComplete
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: location, to: destination)
            completed = true
            onComplete(.success(()))
        } catch {
            completed = true
            onComplete(.failure(error))
        }
        session.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress?(progress)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !completed else { return }
        if let error = error {
            onComplete(.failure(error))
        } else if let http = task.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            onComplete(.failure(WineError.downloadFailed("HTTP \(http.statusCode)")))
        }
        session.invalidateAndCancel()
    }
}

enum WineError: LocalizedError {
    case wineNotFound
    case prefixSetupFailed
    case downloadFailed(String)
    case extractionFailed
    case invalidURL(String)
    case registryFailed(String)

    var errorDescription: String? {
        switch self {
        case .wineNotFound: return "Wine not found. Please install Wine or download a distribution."
        case .prefixSetupFailed: return "Failed to setup Wine prefix."
        case .downloadFailed(let msg): return "Download failed: \(msg)"
        case .extractionFailed: return "Failed to extract Wine archive."
        case .invalidURL(let url): return "Invalid URL: \(url)"
        case .registryFailed(let msg): return "Registry operation failed: \(msg)"
        }
    }
}
