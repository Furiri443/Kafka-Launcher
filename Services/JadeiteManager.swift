import Foundation

// MARK: - Jadeite Manager (handles Jadeite wrapper patching for HSR)

struct JadeiteManager {

    static let currentVersion = "4.1.0"
    static let downloadURL = "https://codeberg.org/mkrsym1/jadeite/releases/download/v4.1.0/v4.1.0.zip"
    static let jadeitePath = WineManager.basePath + "/jadeite"
    static let jadeiteExe = jadeitePath + "/jadeite.exe"

    // MARK: - Games that require jadeite

    static func requiresJadeite(for gameType: GameType) -> Bool {
        switch gameType {
        case .honkaiStarRail: return true
        case .genshinImpact, .zenlessZoneZero: return false
        }
    }

    // MARK: - Extra launch arguments per game

    static func extraArguments(for gameType: GameType) -> [String] {
        switch gameType {
        case .honkaiStarRail: return ["--", "-disable-gpu-skinning"]
        case .genshinImpact, .zenlessZoneZero: return []
        }
    }

    // MARK: - Ensure jadeite is downloaded

    static func ensureJadeiteAvailable() async throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: jadeiteExe) { return }

        print("Jadeite not found locally, downloading v\(currentVersion)...")
        try await downloadJadeite()
    }

    // MARK: - Download and extract jadeite

    static func downloadJadeite() async throws {
        let fm = FileManager.default
        let dir = jadeitePath
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

        guard let url = URL(string: downloadURL) else { return }

        let zipPath = WineManager.basePath + "/jadeite.zip"
        let (tempURL, response) = try await URLSession.shared.download(from: url)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw JadeiteError.downloadFailed("HTTP \(http.statusCode)")
        }

        if fm.fileExists(atPath: zipPath) { try fm.removeItem(atPath: zipPath) }
        try fm.moveItem(at: tempURL, to: URL(fileURLWithPath: zipPath))

        // Clean existing jadeite dir
        if fm.fileExists(atPath: dir) { try fm.removeItem(atPath: dir) }
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Extract zip
        try await ProcessRunner.runChecked(
            "/usr/bin/unzip",
            arguments: ["-o", zipPath, "-d", dir],
            errorBuilder: { _ in JadeiteError.extractionFailed }
        )

        // Cleanup zip
        try? fm.removeItem(atPath: zipPath)

        // Verify jadeite.exe exists — may be nested in subdirectory
        if !fm.fileExists(atPath: jadeiteExe) {
            if let enumerator = fm.enumerator(atPath: dir) {
                while let file = enumerator.nextObject() as? String {
                    if file.hasSuffix("jadeite.exe") {
                        let fullPath = dir + "/" + file
                        let parentDir = (fullPath as NSString).deletingLastPathComponent
                        if parentDir != dir {
                            for item in (try? fm.contentsOfDirectory(atPath: parentDir)) ?? [] {
                                let src = parentDir + "/" + item
                                let dst = dir + "/" + item
                                if fm.fileExists(atPath: dst) { try? fm.removeItem(atPath: dst) }
                                try? fm.moveItem(atPath: src, toPath: dst)
                            }
                        }
                        break
                    }
                }
            }
        }

        guard fm.fileExists(atPath: jadeiteExe) else {
            throw JadeiteError.jadeiteNotFound
        }

        UserDefaults.standard.set(currentVersion, forKey: "jadeite_downloaded_version")
        print("Jadeite v\(currentVersion) downloaded successfully")
    }
}

// MARK: - Errors

enum JadeiteError: LocalizedError {
    case downloadFailed(String)
    case extractionFailed
    case jadeiteNotFound

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let msg): return "Jadeite download failed: \(msg)"
        case .extractionFailed: return "Failed to extract jadeite archive."
        case .jadeiteNotFound: return "jadeite.exe not found after extraction."
        }
    }
}
