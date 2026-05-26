import Foundation
import CryptoKit

// MARK: - Game Version Detector

struct GameVersionDetector {

    // MARK: - Get Game Version from globalgamemanagers

    /// Reads game version from the Unity `globalgamemanagers` binary file.
    /// Searches for `ic.app-category.` pattern and extracts version string at offset +88.
    static func getGameVersion(gameDataDir: String, offset: Int = 0x88) -> String? {
        let ggmPath = gameDataDir + "/globalgamemanagers"
        guard let data = FileManager.default.contents(atPath: ggmPath) else { return nil }

        // Search for pattern: "ic.app-category." (hex: 69 63 2e 61 70 70 2d 63 61 74 65 67 6f 72 79 2e)
        let pattern: [UInt8] = [0x69, 0x63, 0x2e, 0x61, 0x70, 0x70, 0x2d, 0x63,
                                0x61, 0x74, 0x65, 0x67, 0x6f, 0x72, 0x79, 0x2e]

        guard let patternIndex = findPattern(in: data, pattern: pattern) else {
            return getGameVersion2019(gameDataDir: gameDataDir)
        }

        let versionOffset = patternIndex + offset
        guard versionOffset + 4 < data.count else { return nil }

        // Read string length as uint32 little-endian
        let lengthBytes = data.subdata(in: versionOffset..<(versionOffset + 4))
        let length = lengthBytes.withUnsafeBytes { $0.load(as: UInt32.self) }

        guard length > 0 && length < 100 else { return nil }
        let strStart = versionOffset + 4
        let strEnd = strStart + Int(length)
        guard strEnd <= data.count else { return nil }

        let strData = data.subdata(in: strStart..<strEnd)
        guard let fullString = String(data: strData, encoding: .utf8) else { return nil }

        // Split by "_" and return first component (version)
        return fullString.split(separator: "_").first.map(String.init)
    }

    // MARK: - Fallback: data.unity3d version detection

    static func getGameVersion2019(gameDataDir: String) -> String? {
        let dataPath = gameDataDir + "/data.unity3d"
        guard let data = FileManager.default.contents(atPath: dataPath) else { return nil }

        // Search for "category" pattern
        let pattern: [UInt8] = [0x63, 0x61, 0x74, 0x65, 0x67, 0x6f, 0x72, 0x79]
        if findPattern(in: data, pattern: pattern) != nil {
            // Try to find version near the pattern (dots indicate version numbers)
            // Version format: X.Y.Z
            return extractVersionNearPattern(in: data, pattern: pattern)
        }

        // Fallback: MD5-based detection for very old versions
        return md5VersionMapping(dataPath: dataPath)
    }

    // MARK: - Detect Installed Version

    static func detectInstalledVersion(gameType: GameType, installDir: String) -> String? {
        let dataDir = installDir + "/" + gameType.dataDir

        // Try primary method first
        if let version = getGameVersion(gameDataDir: dataDir) {
            return version
        }

        // Try 2019 fallback
        if let version = getGameVersion2019(gameDataDir: dataDir) {
            return version
        }

        return nil
    }

    // MARK: - Private Helpers

    private static func findPattern(in data: Data, pattern: [UInt8]) -> Int? {
        let bytes = [UInt8](data)
        guard pattern.count <= bytes.count else { return nil }

        for i in 0...(bytes.count - pattern.count) {
            var found = true
            for j in 0..<pattern.count {
                if bytes[i + j] != pattern[j] {
                    found = false
                    break
                }
            }
            if found { return i }
        }
        return nil
    }

    private static func extractVersionNearPattern(in data: Data, pattern: [UInt8]) -> String? {
        guard let index = findPattern(in: data, pattern: pattern) else { return nil }
        let bytes = [UInt8](data)

        // Search forward from pattern for a version-like string (X.Y.Z)
        let searchStart = index
        let searchEnd = min(index + 500, bytes.count)

        var versionStart = -1
        for i in searchStart..<searchEnd {
            let c = bytes[i]
            if c >= 0x30 && c <= 0x39 { // digit
                if versionStart == -1 { versionStart = i }
            } else if c == 0x2E && versionStart != -1 { // dot
                continue
            } else if versionStart != -1 {
                let candidate = String(bytes: Array(bytes[versionStart..<i]), encoding: .utf8) ?? ""
                if candidate.contains(".") && candidate.count >= 3 {
                    return candidate
                }
                versionStart = -1
            }
        }
        return nil
    }

    private static func md5VersionMapping(dataPath: String) -> String? {
        guard let data = FileManager.default.contents(atPath: dataPath) else { return nil }

        let digest = Insecure.MD5.hash(data: data)
        let md5 = digest.map { String(format: "%02x", $0) }.joined()

        let mappings: [String: String] = [
            "57dad95088363b87e0c1ab614fe9431c": "3.1.0",
            "a62a4da2e7bb1b1c3fe725173b9bcd64": "3.2.0",
            "28fa1997e51c707d13979ad8b9aed759": "3.6.0",
            "3602065e153d9782a0f0cf4a73a98b44": "3.8.0",
        ]

        return mappings[md5]
    }
}
