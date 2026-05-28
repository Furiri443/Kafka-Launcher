import Foundation

// MARK: - DXMT Manager (handles DXMT/DXVK DLL placement with version-aware logic)

struct DXMTManager {

    // MARK: - Constants

    static let currentDXMTVersion = "0.80"

    // Core DXMT DLLs
    static let coreDLLs = ["d3d10core.dll", "d3d11.dll", "dxgi.dll"]
    static let metalDLLWindows = "winemetal.dll"
    static let metalDLLUnix = "winemetal.so"
    static let nvngxDLL = "nvngx.dll"

    // DXMT download URLs
    struct DXMTRelease {
        let version: String
        let url: String
    }

    static let latestRelease = DXMTRelease(
        version: "0.80",
        url: "https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz"
    )

    // MARK: - Ensure DXMT is downloaded

    static func ensureDXMTAvailable() async throws {
        let fm = FileManager.default
        let dxmtDir = WineManager.dxmtPath
        let testDLL = dxmtDir + "/d3d11.dll"

        if !fm.fileExists(atPath: testDLL) {
            print("DXMT not found locally, downloading v\(latestRelease.version)...")
            try await downloadDXMT()
        }
    }

    // MARK: - Place DXMT DLLs

    static func placeDXMTDLLs(
        gameDir: String,
        winePrefix: String,
        installedVersion: String?,
        gameType: GameType,
        onProgress: ((String) -> Void)? = nil
    ) throws {
        let fm = FileManager.default
        let dxmtDir = WineManager.dxmtPath
        let version = installedVersion ?? currentDXMTVersion

        // Determine placement location based on version
        // If version < 0.74.0: DLLs go to system32 (native override)
        // If version >= 0.74.0: DLLs go to wine lib (builtin replacement) — e.g. dxmt-v0.74-builtin.tar.gz
        let isBuiltinDXMT = compareVersions(version, "0.74") >= 0

        let system32 = winePrefix + "/drive_c/windows/system32"

        // Auto-detect Wine lib directory (x86_64-windows or i386-windows for WoW64)
        let wineLib = resolveWineLibDir(arch: "windows")
        let wineUnixLib = resolveWineLibDir(arch: "unix")

        let targetDir = isBuiltinDXMT ? wineLib : system32

        onProgress?("Placing DXMT DLLs (\(isBuiltinDXMT ? "builtin" : "native") mode) to \(targetDir)...")
        print("[DXMT] isBuiltinDXMT=\(isBuiltinDXMT), version=\(version), targetDir=\(targetDir)")
        print("[DXMT] dxmtDir=\(dxmtDir)")

        // Place core DLLs
        for dll in coreDLLs {
            let srcPath = dxmtDir + "/" + dll
            let destPath = targetDir + "/" + dll
            let bakPath = destPath + ".bak"

            guard fm.fileExists(atPath: srcPath) else {
                print("[DXMT] ⚠️ Source not found: \(srcPath)")
                continue
            }

            let srcSize = (try? fm.attributesOfItem(atPath: srcPath)[.size] as? Int) ?? 0
            print("[DXMT] Copying \(dll): \(srcSize) bytes → \(destPath)")

            // Backup existing
            if fm.fileExists(atPath: destPath) && !fm.fileExists(atPath: bakPath) {
                try fm.copyItem(atPath: destPath, toPath: bakPath)
                print("[DXMT]   Backed up original to \(bakPath)")
            }

            if fm.fileExists(atPath: destPath) {
                try fm.removeItem(atPath: destPath)
            }
            try fm.copyItem(atPath: srcPath, toPath: destPath)

            let destSize = (try? fm.attributesOfItem(atPath: destPath)[.size] as? Int) ?? 0
            print("[DXMT]   Result: \(destSize) bytes at \(destPath)")
        }

        // winemetal.dll → wine lib AND system32 (overwrite, NO backup)
        // cp(`./dxmt/winemetal.dll`, resolve("./wine/lib/wine/x86_64-windows/winemetal.dll"))
        // cp(`./dxmt/winemetal.dll`, join(system32Dir, "winemetal.dll"))
        let metalSrc = dxmtDir + "/" + metalDLLWindows
        if fm.fileExists(atPath: metalSrc) {
            for dest in [wineLib, system32] {
                let destPath = dest + "/" + metalDLLWindows
                if fm.fileExists(atPath: destPath) { try fm.removeItem(atPath: destPath) }
                try fm.copyItem(atPath: metalSrc, toPath: destPath)
                print("[DXMT] Placed \(metalDLLWindows) → \(destPath)")
            }
        }

        // winemetal.so → wine unix lib (overwrite, NO backup)
        // cp(`./dxmt/winemetal.so`, resolve("./wine/lib/wine/x86_64-unix/winemetal.so"))
        let metalSoSrc = dxmtDir + "/" + metalDLLUnix
        if fm.fileExists(atPath: metalSoSrc) {
            try fm.createDirectory(atPath: wineUnixLib, withIntermediateDirectories: true)
            let destPath = wineUnixLib + "/" + metalDLLUnix
            if fm.fileExists(atPath: destPath) { try fm.removeItem(atPath: destPath) }
            try fm.copyItem(atPath: metalSoSrc, toPath: destPath)
            print("[DXMT] Placed \(metalDLLUnix) → \(destPath)")
        }

        // nvngx.dll for HKRPG (Star Rail) only — wine lib AND system32 (NO backup)
        if gameType == .honkaiStarRail {
            let nvSrc = dxmtDir + "/" + nvngxDLL
            if fm.fileExists(atPath: nvSrc) {
                for dest in [wineLib, system32] {
                    let destPath = dest + "/" + nvngxDLL
                    if fm.fileExists(atPath: destPath) { try fm.removeItem(atPath: destPath) }
                    try fm.copyItem(atPath: nvSrc, toPath: destPath)
                    print("[DXMT] Placed \(nvngxDLL) → \(destPath)")
                }
            }
        }

        // Store installed version
        UserDefaults.standard.set(version, forKey: "\(gameType.rawValue)_installed_dxmt_version")
        onProgress?("DXMT DLLs placed successfully")
    }

    // MARK: - Revert DXMT DLLs (only core DLLs)

    static func revertDXMTDLLs(
        winePrefix: String,
        installedVersion: String?,
        gameType: GameType
    ) throws {
        let fm = FileManager.default
        let version = installedVersion ?? currentDXMTVersion
        let isBuiltinDXMT = compareVersions(version, "0.74") >= 0

        let system32 = winePrefix + "/drive_c/windows/system32"
        let wineLib = resolveWineLibDir(arch: "windows")

        let targetDir = isBuiltinDXMT ? wineLib : system32

        // Restoration details:
        //   for (const f of DXMT_FILES) {
        //     const wineLibPath = resolve(`./wine/lib/wine/x86_64-windows/${f}`);
        //     await forceMove(wineLibPath + ".bak", wineLibPath);
        //   }
        // Only restores core DLLs — winemetal and nvngx are NEVER reverted
        for dll in coreDLLs {
            let destPath = targetDir + "/" + dll
            let bakPath = destPath + ".bak"
            if fm.fileExists(atPath: bakPath) {
                if fm.fileExists(atPath: destPath) { try fm.removeItem(atPath: destPath) }
                try fm.moveItem(atPath: bakPath, toPath: destPath)
            }
        }
    }

    // MARK: - Wine Lib Directory Resolution

    /// Resolve the correct Wine lib directory, handling both standard (x86_64-*) and WoW64 (i386-*) builds
    private static func resolveWineLibDir(arch: String) -> String {
        let base = WineManager.winePath + "/lib/wine"
        let x64 = base + "/x86_64-\(arch)"
        let i386 = base + "/i386-\(arch)"
        if FileManager.default.fileExists(atPath: x64) { return x64 }
        if FileManager.default.fileExists(atPath: i386) { return i386 }
        return x64 // fallback
    }

    // MARK: - Download DXMT

    static func downloadDXMT(onProgress: ((Double) -> Void)? = nil) async throws {
        let fm = FileManager.default
        let dxmtDir = WineManager.dxmtPath
        try fm.createDirectory(atPath: dxmtDir, withIntermediateDirectories: true)

        guard let url = URL(string: latestRelease.url) else { return }

        let archivePath = WineManager.basePath + "/dxmt.tar.gz"
        let extractTmp = WineManager.basePath + "/dxmt_tmp"
        let (tempURL, _) = try await URLSession.shared.download(from: url)

        if fm.fileExists(atPath: archivePath) { try fm.removeItem(atPath: archivePath) }
        try fm.moveItem(at: tempURL, to: URL(fileURLWithPath: archivePath))

        // Extract to temp dir
        if fm.fileExists(atPath: extractTmp) { try fm.removeItem(atPath: extractTmp) }
        try fm.createDirectory(atPath: extractTmp, withIntermediateDirectories: true)

        try await ProcessRunner.run(
            "/usr/bin/tar",
            arguments: ["xzf", archivePath, "-C", extractTmp]
        )

        // Move DLLs from v0.xx/x86_64-windows/ and v0.xx/x86_64-unix/ to dxmtDir
        let versionDir = extractTmp + "/v\(latestRelease.version)"
        let winDir = versionDir + "/x86_64-windows"
        let unixDir = versionDir + "/x86_64-unix"

        // Clean existing DLLs
        if fm.fileExists(atPath: dxmtDir) { try fm.removeItem(atPath: dxmtDir) }
        try fm.createDirectory(atPath: dxmtDir, withIntermediateDirectories: true)

        // Copy x86_64-windows DLLs
        if fm.fileExists(atPath: winDir) {
            for file in try fm.contentsOfDirectory(atPath: winDir) {
                try fm.copyItem(atPath: winDir + "/" + file, toPath: dxmtDir + "/" + file)
            }
        }

        // Copy x86_64-unix DLLs (winemetal.so)
        if fm.fileExists(atPath: unixDir) {
            for file in try fm.contentsOfDirectory(atPath: unixDir) {
                try fm.copyItem(atPath: unixDir + "/" + file, toPath: dxmtDir + "/" + file)
            }
        }

        // Cleanup
        try? fm.removeItem(atPath: archivePath)
        try? fm.removeItem(atPath: extractTmp)

        UserDefaults.standard.set(latestRelease.version, forKey: "dxmt_downloaded_version")
    }

    // MARK: - DLL Override Environment Variables
    // For builtin DXMT (>=0.74): DLLs replace wine lib originals, no override needed
    // For native DXMT (<0.74): DLLs in system32, need override to prefer native

    static func dllOverrideString(enableDXMT: Bool, installedVersion: String? = nil) -> String {
        if enableDXMT {
            let version = installedVersion ?? currentDXMTVersion
            let isBuiltin = compareVersions(version, "0.74") >= 0
            // Builtin mode: DLLs are in wine lib, no override needed
            if isBuiltin { return "" }
            return "d3d11,dxgi=n,b"
        }
        return ""
    }

    // MARK: - Version Comparison

    private static func compareVersions(_ a: String, _ b: String) -> Int {
        let partsA = a.split(separator: ".").compactMap { Int($0) }
        let partsB = b.split(separator: ".").compactMap { Int($0) }
        let maxLen = max(partsA.count, partsB.count)
        for i in 0..<maxLen {
            let va = i < partsA.count ? partsA[i] : 0
            let vb = i < partsB.count ? partsB[i] : 0
            if va != vb { return va < vb ? -1 : 1 }
        }
        return 0
    }
}
