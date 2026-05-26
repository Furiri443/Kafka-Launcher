import Foundation
import CryptoKit

// MARK: - Registry Manager

struct RegistryManager {

    // MARK: - Generate UTF-16LE Registry File

    static func generateRegistryFile(entries: [(key: String, values: [(name: String, value: RegistryValue)])]) -> Data {
        var content = "Windows Registry Editor Version 5.00\r\n\r\n"

        for entry in entries {
            content += "[\(entry.key)]\r\n"
            for (name, value) in entry.values {
                switch value {
                case .string(let s):
                    content += "\"\(name)\"=\"\(s)\"\r\n"
                case .dword(let d):
                    content += "\"\(name)\"=dword:\(String(format: "%08x", d))\r\n"
                case .hex(let bytes):
                    let hexStr = bytes.map { String(format: "%02x", $0) }.joined(separator: ",")
                    content += "\"\(name)\"=hex:\(hexStr)\r\n"
                }
            }
            content += "\r\n"
        }

        // Encode as UTF-16LE with BOM
        var data = Data([0xFF, 0xFE]) // UTF-16LE BOM
        if let encoded = content.data(using: .utf16LittleEndian) {
            data.append(encoded)
        }
        return data
    }

    // MARK: - HDR Registry

    static func generateHDRRegistry(gameType: GameType, enable: Bool) -> Data {
        let regKey: String
        switch gameType {
        case .genshinImpact:
            regKey = "HKEY_CURRENT_USER\\Software\\\\x6d\\x69\\x48\\x6f\\x59\\x6f\\\\GenshinImpact"
        case .honkaiStarRail:
            regKey = "HKEY_CURRENT_USER\\Software\\Cognosphere\\Star Rail"
        case .zenlessZoneZero:
            regKey = "HKEY_CURRENT_USER\\Software\\miHoYo\\ZenlessZoneZero"
        }

        let hdrValue: UInt32 = enable ? 1 : 0
        return generateRegistryFile(entries: [
            (key: regKey, values: [
                ("WINDOWS_HDR_ON_h3132281285", .dword(hdrValue))
            ])
        ])
    }

    // MARK: - Custom Resolution Registry

    static func generateResolutionRegistry(
        gameType: GameType,
        width: Int,
        height: Int,
        fullscreen: Bool = false
    ) -> Data {
        let regKey: String
        switch gameType {
        case .genshinImpact:
            regKey = "HKEY_CURRENT_USER\\Software\\\\x6d\\x69\\x48\\x6f\\x59\\x6f\\\\GenshinImpact"
        case .honkaiStarRail:
            regKey = "HKEY_CURRENT_USER\\Software\\Cognosphere\\Star Rail"
        case .zenlessZoneZero:
            regKey = "HKEY_CURRENT_USER\\Software\\miHoYo\\ZenlessZoneZero"
        }

        // Encode width/height as hex (little-endian int32)
        let widthBytes = withUnsafeBytes(of: Int32(width).littleEndian) { Array($0) }
        let heightBytes = withUnsafeBytes(of: Int32(height).littleEndian) { Array($0) }
        let fullscreenValue: UInt32 = fullscreen ? 1 : 0

        return generateRegistryFile(entries: [
            (key: regKey, values: [
                ("Screenmanager Resolution Width_h182942802", .hex(widthBytes.map { UInt8($0) })),
                ("Screenmanager Resolution Height_h2627697771", .hex(heightBytes.map { UInt8($0) })),
                ("Screenmanager Is Fullscreen mode_h3981298716", .dword(fullscreenValue)),
            ])
        ])
    }

    // MARK: - DLL Override Registry

    static func generateDLLOverrideRegistry(dlls: [(name: String, mode: String)]) -> Data {
        let values: [(String, RegistryValue)] = dlls.map { ($0.name, .string($0.mode)) }
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

    // MARK: - Revert Registry File (delete the temp file)

    static func revertRegistryFile(path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Proxy Registry
    
    static func generateProxyRegistry(enable: Bool, proxyHost: String) -> Data {
        let regKey = "HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings"
        
        var values: [(name: String, value: RegistryValue)] = []
        if enable && !proxyHost.isEmpty {
            values.append(("ProxyEnable", .dword(1)))
            values.append(("ProxyServer", .string(proxyHost)))
            values.append(("ProxyOverride", .string("<local>")))
        } else {
            values.append(("ProxyEnable", .dword(0)))
        }
        
        return generateRegistryFile(entries: [(key: regKey, values: values)])
    }

    // MARK: - Import macOS Root and User Certificates into Wine
    
    static func importMacCertificates(wineManager: WineManager, prefix: String) async throws -> String? {
        // 1. Get PEM certificates from security command
        guard let pemData = try? await ProcessRunner.runAndCapture(
            "/usr/bin/security",
            arguments: ["find-certificate", "-a", "-p"]
        ), let pemStr = String(data: pemData, encoding: .utf8) else {
            print("[CertImport] ⚠️ Failed to export certificates using security command")
            return nil
        }
        
        let components = pemStr.components(separatedBy: "-----BEGIN CERTIFICATE-----")
        var entries: [(key: String, values: [(name: String, value: RegistryValue)])] = []
        
        for comp in components {
            guard comp.contains("-----END CERTIFICATE-----") else { continue }
            let parts = comp.components(separatedBy: "-----END CERTIFICATE-----")
            guard let base64Str = parts.first else { continue }
            
            // Clean up base64 string
            let cleanBase64 = base64Str.replacingOccurrences(of: "\n", with: "")
                                        .replacingOccurrences(of: "\r", with: "")
                                        .replacingOccurrences(of: " ", with: "")
            
            guard let derData = Data(base64Encoded: cleanBase64) else { continue }
            
            // Compute SHA-1
            let hash = Insecure.SHA1.hash(data: derData)
            let hashBytes = Array(hash)
            let hashHex = hashBytes.map { String(format: "%02X", $0) }.joined()
            
            // Build Windows Registry Cert Blob
            var blob = Data()
            
            // SHA-1 Hash Property (ID = 3)
            blob.append(contentsOf: [0x03, 0x00, 0x00, 0x00])
            blob.append(contentsOf: [0x01, 0x00, 0x00, 0x00])
            blob.append(contentsOf: [0x14, 0x00, 0x00, 0x00])
            blob.append(contentsOf: hashBytes)
            
            // Certificate DER Property (ID = 32)
            blob.append(contentsOf: [0x20, 0x00, 0x00, 0x00])
            blob.append(contentsOf: [0x01, 0x00, 0x00, 0x00])
            let derLength = UInt32(derData.count)
            let derLengthBytes = withUnsafeBytes(of: derLength.littleEndian) { Array($0) }
            blob.append(contentsOf: derLengthBytes)
            blob.append(derData)
            
            let blobBytes = Array(blob)
            
            // Add entries for Root and CA stores
            let rootKey = "HKEY_CURRENT_USER\\Software\\Microsoft\\SystemCertificates\\Root\\Certificates\\\(hashHex)"
            let caKey = "HKEY_CURRENT_USER\\Software\\Microsoft\\SystemCertificates\\CA\\Certificates\\\(hashHex)"
            
            entries.append((key: rootKey, values: [("Blob", .hex(blobBytes))]))
            entries.append((key: caKey, values: [("Blob", .hex(blobBytes))]))
        }
        
        guard !entries.isEmpty else {
            print("[CertImport] No certificates parsed from macOS keychain")
            return nil
        }
        
        // Write all to a single reg file and apply
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
        guard let fileData = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }
        
        var derDataList: [Data] = []
        
        if let pemStr = String(data: fileData, encoding: .utf8),
           pemStr.contains("-----BEGIN CERTIFICATE-----") {
            let components = pemStr.components(separatedBy: "-----BEGIN CERTIFICATE-----")
            for comp in components {
                guard comp.contains("-----END CERTIFICATE-----") else { continue }
                let parts = comp.components(separatedBy: "-----END CERTIFICATE-----")
                guard let base64Str = parts.first else { continue }
                
                let cleanBase64 = base64Str.replacingOccurrences(of: "\n", with: "")
                                            .replacingOccurrences(of: "\r", with: "")
                                            .replacingOccurrences(of: " ", with: "")
                
                if let derData = Data(base64Encoded: cleanBase64) {
                    derDataList.append(derData)
                }
            }
        } else {
            // Assume the file is already raw DER data
            derDataList.append(fileData)
        }
        
        guard !derDataList.isEmpty else { return nil }
        
        var entries: [(key: String, values: [(name: String, value: RegistryValue)])] = []
        
        for derData in derDataList {
            // Compute SHA-1
            let hash = Insecure.SHA1.hash(data: derData)
            let hashBytes = Array(hash)
            let hashHex = hashBytes.map { String(format: "%02X", $0) }.joined()
            
            // Build Windows Registry Cert Blob
            var blob = Data()
            
            // SHA-1 Hash Property (ID = 3)
            blob.append(contentsOf: [0x03, 0x00, 0x00, 0x00])
            blob.append(contentsOf: [0x01, 0x00, 0x00, 0x00])
            blob.append(contentsOf: [0x14, 0x00, 0x00, 0x00])
            blob.append(contentsOf: hashBytes)
            
            // Certificate DER Property (ID = 32)
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
        
        guard !entries.isEmpty else { return nil }
        
        let regData = generateRegistryFile(entries: entries)
        return try await writeAndApply(
            data: regData,
            fileName: "private_server_cert.reg",
            wineManager: wineManager,
            prefix: prefix
        )
    }
}

// MARK: - Registry Value Type

enum RegistryValue {
    case string(String)
    case dword(UInt32)
    case hex([UInt8])
}
