import Foundation
import CryptoKit

// MARK: - Registry Manager

struct RegistryManager {
    typealias Entry = (key: String, values: [(name: String, value: RegistryValue)])

    // MARK: - Generate UTF-16LE Registry File

    static func generateRegistryFile(entries: [Entry]) -> Data {
        var content = "Windows Registry Editor Version 5.00\r\n\r\n"

        for entry in entries {
            content += "[\(entry.key)]\r\n"
            for (name, value) in entry.values {
                let escapedName = escapeRegistryString(name)
                switch value {
                case .string(let s):
                    content += "\"\(escapedName)\"=\"\(escapeRegistryString(s))\"\r\n"
                case .dword(let d):
                    content += "\"\(escapedName)\"=dword:\(String(format: "%08x", d))\r\n"
                case .hex(let bytes):
                    let hexStr = bytes.map { String(format: "%02x", $0) }.joined(separator: ",")
                    content += "\"\(escapedName)\"=hex:\(hexStr)\r\n"
                }
            }
            content += "\r\n"
        }

        var data = Data([0xFF, 0xFE])
        if let encoded = content.data(using: .utf16LittleEndian) {
            data.append(encoded)
        }
        return data
    }

    private static func escapeRegistryString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Wine Launch Registry

    static func generateWinePropsRegistryEntries(retinaMode: Bool, leftCommandIsCtrl: Bool) -> [Entry] {
        [
            (
                key: "HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver",
                values: [
                    ("RetinaMode", .string(retinaMode ? "y" : "n")),
                    ("LeftCommandIsCtrl", .string(leftCommandIsCtrl ? "y" : "n")),
                ]
            )
        ]
    }

    static func generateNVExtensionRegistryEntries() -> [Entry] {
        [
            (
                key: "HKEY_LOCAL_MACHINE\\SOFTWARE\\NVIDIA Corporation\\Global",
                values: [("{41FCC608-8496-4DEF-B43E-7D9BD675A6FF}", .hex([0x01]))]
            ),
            (
                key: "HKEY_LOCAL_MACHINE\\SYSTEM\\ControlSet001\\Services\\nvlddmkm",
                values: [("{41FCC608-8496-4DEF-B43E-7D9BD675A6FF}", .hex([0x01]))]
            ),
            (
                key: "HKEY_LOCAL_MACHINE\\SOFTWARE\\NVIDIA Corporation\\Global\\NGXCore",
                values: [("FullPath", .string("C:\\Windows\\System32"))]
            ),
        ]
    }

    // MARK: - HDR Registry

    static func generateHDRRegistryEntries(gameType: GameType, enable: Bool) -> [Entry] {
        let hdrValue: UInt32 = enable ? 1 : 0
        return [
            (
                key: gameSettingsRegistryKey(for: gameType),
                values: [("WINDOWS_HDR_ON_h3132281285", .dword(hdrValue))]
            )
        ]
    }

    static func generateHDRRegistry(gameType: GameType, enable: Bool) -> Data {
        generateRegistryFile(entries: generateHDRRegistryEntries(gameType: gameType, enable: enable))
    }

    // MARK: - Custom Resolution Registry

    static func generateResolutionRegistryEntries(
        gameType: GameType,
        width: Int,
        height: Int,
        fullscreen: Bool = false
    ) -> [Entry] {
        let widthBytes = withUnsafeBytes(of: Int32(width).littleEndian) { Array($0) }
        let heightBytes = withUnsafeBytes(of: Int32(height).littleEndian) { Array($0) }
        let fullscreenValue: UInt32 = fullscreen ? 1 : 0

        return [
            (
                key: gameSettingsRegistryKey(for: gameType),
                values: [
                    ("Screenmanager Resolution Width_h182942802", .hex(widthBytes.map { UInt8($0) })),
                    ("Screenmanager Resolution Height_h2627697771", .hex(heightBytes.map { UInt8($0) })),
                    ("Screenmanager Is Fullscreen mode_h3981298716", .dword(fullscreenValue)),
                ]
            )
        ]
    }

    static func generateResolutionRegistry(
        gameType: GameType,
        width: Int,
        height: Int,
        fullscreen: Bool = false
    ) -> Data {
        generateRegistryFile(
            entries: generateResolutionRegistryEntries(
                gameType: gameType,
                width: width,
                height: height,
                fullscreen: fullscreen
            )
        )
    }

    // MARK: - DLL Override Registry

    static func generateDLLOverrideRegistry(dlls: [(name: String, mode: String)]) -> Data {
        let values: [(name: String, value: RegistryValue)] = dlls.map { ($0.name, .string($0.mode)) }
        return generateRegistryFile(entries: [
            (key: "HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides", values: values)
        ])
    }

    // MARK: - Write and Apply Registry File

    static func writeAndApply(
        data: Data,
        fileName: String,
        wineManager: WineManager,
        prefix: String? = nil
    ) async throws -> String {
        let tempDir = WineManager.basePath + "/temp"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        let filePath = tempDir + "/" + fileName
        try data.write(to: URL(fileURLWithPath: filePath))

        try await wineManager.applyRegistryFile(filePath, prefix: prefix)
        return filePath
    }

    // MARK: - Revert Registry File

    static func revertRegistryFile(path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Proxy Registry

    static func generateProxyRegistryEntries(enable: Bool, proxyHost: String) -> [Entry] {
        let regKey = "HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings"

        var values: [(name: String, value: RegistryValue)] = []
        if enable && !proxyHost.isEmpty {
            values.append(("ProxyEnable", .dword(1)))
            values.append(("ProxyServer", .string(proxyHost)))
            values.append(("ProxyOverride", .string("<local>")))
        } else {
            values.append(("ProxyEnable", .dword(0)))
        }

        return [(key: regKey, values: values)]
    }

    static func generateProxyRegistry(enable: Bool, proxyHost: String) -> Data {
        generateRegistryFile(entries: generateProxyRegistryEntries(enable: enable, proxyHost: proxyHost))
    }

    // MARK: - Certificate Registry

    static func macCertificateRegistryEntries() async -> [Entry]? {
        guard let pemData = try? await ProcessRunner.runAndCapture(
            "/usr/bin/security",
            arguments: ["find-certificate", "-a", "-p"]
        ), let pemStr = String(data: pemData, encoding: .utf8) else {
            print("[CertImport] Failed to export certificates using security command")
            return nil
        }

        let entries = certificateRegistryEntries(fromPEMString: pemStr)
        guard !entries.isEmpty else {
            print("[CertImport] No certificates parsed from macOS keychain")
            return nil
        }

        print("[CertImport] Parsed \(entries.count / 2) certificates from macOS keychain")
        return entries
    }

    static func certificateRegistryEntries(at path: String) -> [Entry]? {
        guard let fileData = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }

        let entries = certificateRegistryEntries(fromCertificateData: fileData)
        return entries.isEmpty ? nil : entries
    }

    static func importMacCertificates(wineManager: WineManager, prefix: String) async throws -> String? {
        guard let entries = await macCertificateRegistryEntries() else {
            return nil
        }

        let regData = generateRegistryFile(entries: entries)
        let path = try await writeAndApply(
            data: regData,
            fileName: "mac_certs.reg",
            wineManager: wineManager,
            prefix: prefix
        )
        print("[CertImport] Successfully imported \(entries.count / 2) certificates from macOS to Wine prefix")
        return path
    }

    static func importCertificate(at path: String, wineManager: WineManager, prefix: String) async throws -> String? {
        guard let entries = certificateRegistryEntries(at: path) else {
            return nil
        }

        let regData = generateRegistryFile(entries: entries)
        return try await writeAndApply(
            data: regData,
            fileName: "private_server_cert.reg",
            wineManager: wineManager,
            prefix: prefix
        )
    }

    private static func gameSettingsRegistryKey(for gameType: GameType) -> String {
        switch gameType {
        case .genshinImpact:
            return "HKEY_CURRENT_USER\\Software\\\\x6d\\x69\\x48\\x6f\\x59\\x6f\\\\GenshinImpact"
        case .honkaiStarRail:
            return "HKEY_CURRENT_USER\\Software\\Cognosphere\\Star Rail"
        case .zenlessZoneZero:
            return "HKEY_CURRENT_USER\\Software\\miHoYo\\ZenlessZoneZero"
        }
    }

    private static func certificateRegistryEntries(fromCertificateData fileData: Data) -> [Entry] {
        if let pemStr = String(data: fileData, encoding: .utf8),
           pemStr.contains("-----BEGIN CERTIFICATE-----") {
            return certificateRegistryEntries(fromPEMString: pemStr)
        }

        return certificateRegistryEntries(fromDERDataList: [fileData])
    }

    private static func certificateRegistryEntries(fromPEMString pemStr: String) -> [Entry] {
        let components = pemStr.components(separatedBy: "-----BEGIN CERTIFICATE-----")
        let derDataList = components.compactMap { comp -> Data? in
            guard comp.contains("-----END CERTIFICATE-----") else { return nil }
            let parts = comp.components(separatedBy: "-----END CERTIFICATE-----")
            guard let base64Str = parts.first else { return nil }

            let cleanBase64 = base64Str
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: " ", with: "")

            return Data(base64Encoded: cleanBase64)
        }

        return certificateRegistryEntries(fromDERDataList: derDataList)
    }

    private static func certificateRegistryEntries(fromDERDataList derDataList: [Data]) -> [Entry] {
        var entries: [Entry] = []

        for derData in derDataList {
            let hash = Insecure.SHA1.hash(data: derData)
            let hashBytes = Array(hash)
            let hashHex = hashBytes.map { String(format: "%02X", $0) }.joined()

            var blob = Data()
            blob.append(contentsOf: [0x03, 0x00, 0x00, 0x00])
            blob.append(contentsOf: [0x01, 0x00, 0x00, 0x00])
            blob.append(contentsOf: [0x14, 0x00, 0x00, 0x00])
            blob.append(contentsOf: hashBytes)

            blob.append(contentsOf: [0x20, 0x00, 0x00, 0x00])
            blob.append(contentsOf: [0x01, 0x00, 0x00, 0x00])
            let derLength = UInt32(derData.count)
            let derLengthBytes = withUnsafeBytes(of: derLength.littleEndian) { Array($0) }
            blob.append(contentsOf: derLengthBytes)
            blob.append(derData)

            let blobBytes = Array(blob)
            let rootKey = "HKEY_CURRENT_USER\\Software\\Microsoft\\SystemCertificates\\Root\\Certificates\\\(hashHex)"
            let caKey = "HKEY_CURRENT_USER\\Software\\Microsoft\\SystemCertificates\\CA\\Certificates\\\(hashHex)"

            entries.append((key: rootKey, values: [("Blob", .hex(blobBytes))]))
            entries.append((key: caKey, values: [("Blob", .hex(blobBytes))]))
        }

        return entries
    }
}

// MARK: - Registry Value Type

enum RegistryValue {
    case string(String)
    case dword(UInt32)
    case hex([UInt8])
}
