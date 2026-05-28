import Foundation
import CryptoKit

// MARK: - Patch Manager (handles binary diff patching via xdelta3, file removal, and injection)

struct PatchManager {

    // MARK: - Patch Definitions

    struct BinaryPatch: Codable {
        let file: String        // Relative path in game directory
        let diffUrl: String     // URL to download .diff file
        let tag: String?        // Optional conditional tag (e.g. "workaround3")
    }

    struct FileRemoval: Codable {
        let file: String
        let tag: String?
    }

    struct FileInjection: Codable {
        let file: String
        let url: String
    }

    struct PatchSet {
        var patched: [BinaryPatch] = []
        var removed: [FileRemoval] = []
        var added: [FileInjection] = []
    }

    // MARK: - Apply All Patches

    static func applyPatches(
        patchSet: PatchSet,
        gameDir: String,
        config: GameConfig,
        onProgress: ((String) -> Void)? = nil
    ) async throws {
        let fm = FileManager.default

        // Check if already patched (prevent double-patching)
        let patchedFlag = UserDefaults.standard.string(forKey: patchedKey(for: config.gameType))
        if patchedFlag == "1" {
            onProgress?("Already patched, skipping...")
            return
        }

        // 1. Apply binary delta patches (xdelta3)
        for patch in patchSet.patched {
            // Check conditional tag
            if let tag = patch.tag, tag == "workaround3" {
                // Skip if workaround3 is disabled in config
                continue
            }

            let filePath = gameDir + "/" + patch.file
            let bakPath = filePath + ".bak"
            let diffPath = filePath + ".diff"

            onProgress?("Patching \(patch.file)...")

            // Backup original
            if fm.fileExists(atPath: filePath) && !fm.fileExists(atPath: bakPath) {
                try fm.copyItem(atPath: filePath, toPath: bakPath)
            }

            // Download diff
            guard let diffURL = URL(string: patch.diffUrl) else { continue }
            let (tempURL, _) = try await URLSession.shared.download(from: diffURL)
            if fm.fileExists(atPath: diffPath) { try fm.removeItem(atPath: diffPath) }
            try fm.moveItem(at: tempURL, to: URL(fileURLWithPath: diffPath))

            // Apply xdelta3: xdelta3 -d -s original.bak patch.diff output
            try await applyXDelta3(source: bakPath, diff: diffPath, output: filePath)

            // Clean up diff file
            try? fm.removeItem(atPath: diffPath)
        }

        // 2. Apply file removals (move to .bak)
        for removal in patchSet.removed {
            if let tag = removal.tag, tag == "workaround3" { continue }

            let filePath = gameDir + "/" + removal.file
            let bakPath = filePath + ".bak"

            if fm.fileExists(atPath: filePath) {
                onProgress?("Removing \(removal.file)...")
                if !fm.fileExists(atPath: bakPath) {
                    try fm.moveItem(atPath: filePath, toPath: bakPath)
                } else {
                    try fm.removeItem(atPath: filePath)
                }
            }
        }

        // 3. Apply file injections (download and place)
        for injection in patchSet.added {
            let filePath = gameDir + "/" + injection.file

            onProgress?("Adding \(injection.file)...")

            guard let url = URL(string: injection.url) else { continue }
            let (tempURL, _) = try await URLSession.shared.download(from: url)

            // Ensure parent directory exists
            let parentDir = (filePath as NSString).deletingLastPathComponent
            try fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

            if fm.fileExists(atPath: filePath) { try fm.removeItem(atPath: filePath) }
            try fm.moveItem(at: tempURL, to: URL(fileURLWithPath: filePath))
        }

        // Set patched flag
        UserDefaults.standard.set("1", forKey: patchedKey(for: config.gameType))
        onProgress?("Patches applied successfully")
    }

    // MARK: - Revert All Patches

    static func revertPatches(
        patchSet: PatchSet,
        gameDir: String,
        gameType: GameType,
        onProgress: ((String) -> Void)? = nil
    ) throws {
        let fm = FileManager.default

        // 1. Revert binary delta patches
        for patch in patchSet.patched {
            let filePath = gameDir + "/" + patch.file
            let bakPath = filePath + ".bak"

            if fm.fileExists(atPath: bakPath) {
                onProgress?("Reverting \(patch.file)...")
                if fm.fileExists(atPath: filePath) {
                    try fm.removeItem(atPath: filePath)
                }
                try fm.moveItem(atPath: bakPath, toPath: filePath)
            }
        }

        // 2. Revert file removals (restore .bak)
        for removal in patchSet.removed {
            let filePath = gameDir + "/" + removal.file
            let bakPath = filePath + ".bak"

            if fm.fileExists(atPath: bakPath) {
                onProgress?("Restoring \(removal.file)...")
                if fm.fileExists(atPath: filePath) {
                    try fm.removeItem(atPath: filePath)
                }
                try fm.moveItem(atPath: bakPath, toPath: filePath)
            }
        }

        // 3. Remove injected files
        for injection in patchSet.added {
            let filePath = gameDir + "/" + injection.file
            if fm.fileExists(atPath: filePath) {
                onProgress?("Removing injected \(injection.file)...")
                try fm.removeItem(atPath: filePath)
            }
        }

        // Clear patched flag
        UserDefaults.standard.removeObject(forKey: patchedKey(for: gameType))
        onProgress?("Patches reverted successfully")
    }

    // MARK: - xdelta3 Binary Delta Application

    private static func applyXDelta3(source: String, diff: String, output: String) async throws {
        // Try system xdelta3 first, then bundled
        let xdelta3Paths = [
            "/opt/homebrew/bin/xdelta3",
            "/usr/local/bin/xdelta3",
            Bundle.main.resourcePath.map { $0 + "/xdelta3" },
        ].compactMap { $0 }

        guard let xdelta3 = xdelta3Paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw PatchError.xdelta3NotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: xdelta3)
        process.arguments = ["-d", "-s", source, diff, output]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw PatchError.xdelta3Failed(file: (output as NSString).lastPathComponent)
        }
    }

    // MARK: - Integrity Check

    static func verifyFileIntegrity(
        gameDir: String,
        fileList: [(path: String, md5: String, size: Int64)],
        onProgress: ((Double, String) -> Void)? = nil
    ) async -> [(path: String, issue: IntegrityIssue)] {
        var issues: [(String, IntegrityIssue)] = []
        let fm = FileManager.default

        for (index, file) in fileList.enumerated() {
            let progress = Double(index) / Double(fileList.count)
            onProgress?(progress, "Checking \(file.path)...")

            let fullPath = gameDir + "/" + file.path

            guard fm.fileExists(atPath: fullPath) else {
                issues.append((file.path, .missing))
                continue
            }

            // Size check
            if let attrs = try? fm.attributesOfItem(atPath: fullPath),
               let fileSize = attrs[.size] as? Int64 {
                if fileSize != file.size {
                    issues.append((file.path, .sizeMismatch(expected: file.size, actual: fileSize)))
                    continue
                }
            }

            // MD5 check
            let actualMD5 = md5OfFile(atPath: fullPath)
            if actualMD5 != file.md5.lowercased() {
                issues.append((file.path, .hashMismatch))
            }
        }

        return issues
    }

    // MARK: - MD5 Calculation

    static func md5OfFile(atPath path: String) -> String {
        guard let data = FileManager.default.contents(atPath: path) else { return "" }
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Helpers

    private static func patchedKey(for gameType: GameType) -> String {
        "\(gameType.rawValue)_patched"
    }

    enum IntegrityIssue {
        case missing
        case sizeMismatch(expected: Int64, actual: Int64)
        case hashMismatch
    }

    enum PatchError: LocalizedError {
        case xdelta3NotFound
        case xdelta3Failed(file: String)
        case downloadFailed(String)

        var errorDescription: String? {
            switch self {
            case .xdelta3NotFound: return "xdelta3 not found. Install with: brew install xdelta"
            case .xdelta3Failed(let f): return "Failed to apply patch to \(f)"
            case .downloadFailed(let msg): return "Patch download failed: \(msg)"
            }
        }
    }
}
