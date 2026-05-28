import Foundation
import AppKit

@Observable
class AppUpdater: NSObject, URLSessionDownloadDelegate {
    static let shared = AppUpdater()
    
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }
    
    var isChecking = false
    var isDownloading = false
    var updateProgress: Double = 0.0
    var updateStatus: String = ""
    var updateAvailable = false
    var showUpdatePrompt = false
    var latestVersion: String?
    var releaseNotes: String?
    var downloadURL: URL?
    
    private var downloadTask: URLSessionDownloadTask?
    private var session: URLSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private var destinationURL: URL?

    private struct GitHubRelease: Decodable {
        let tag_name: String
        let body: String?
        let assets: [ReleaseAsset]
    }

    private struct ReleaseAsset: Decodable {
        let name: String
        let browser_download_url: String
    }
    
    override init() {
        super.init()
    }
    
    // Check if there is an update
    func checkForUpdates(prompt: Bool = false) async -> Bool {
        guard !isChecking && !isDownloading else { return updateAvailable }
        
        await MainActor.run {
            isChecking = true
            updateStatus = "Checking for updates..."
        }
        
        do {
            let url = URL(string: "https://api.github.com/repos/Furiri443/Kafka-Launcher/releases/latest")!
            var request = URLRequest(url: url)
            request.setValue("Kafka-Launcher-Updater", forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                await MainActor.run {
                    isChecking = false
                    updateStatus = "Failed to fetch updates"
                }
                return false
            }
            
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let latestVer = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).trimmingCharacters(in: .whitespacesAndNewlines)
            let currentVer = currentVersion.trimmingCharacters(in: .whitespacesAndNewlines)
            
            let isNewer = latestVer.compare(currentVer, options: .numeric) == .orderedDescending
            let selectedDownloadURL = Self.preferredAsset(from: release.assets)
                .flatMap { URL(string: $0.browser_download_url) }
            
            await MainActor.run {
                self.isChecking = false
                self.latestVersion = latestVer
                self.releaseNotes = release.body
                if isNewer {
                    self.downloadURL = selectedDownloadURL
                    self.updateAvailable = selectedDownloadURL != nil
                    self.updateStatus = self.updateAvailable
                        ? "New version \(latestVer) is available."
                        : "New version \(latestVer) found, but no compatible download asset is available."
                    if prompt && self.updateAvailable {
                        self.showUpdatePrompt = true
                    }
                } else {
                    self.updateAvailable = false
                    self.updateStatus = "Kafka Launcher is up to date."
                }
            }
            return isNewer && selectedDownloadURL != nil
        } catch {
            print("Failed to check for updates: \(error)")
            await MainActor.run {
                self.isChecking = false
                self.updateStatus = "Error checking updates: \(error.localizedDescription)"
            }
            return false
        }
    }
    
    // Download and install update
    func installUpdate() async {
        guard let downloadURL = downloadURL, !isDownloading else { return }
        
        await MainActor.run {
            isDownloading = true
            updateProgress = 0.0
            updateStatus = "Downloading update..."
        }
        
        let config = URLSessionConfiguration.default
        let s = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = s
        
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let zipPath = tempDir.appendingPathComponent("update.zip")
        self.destinationURL = zipPath
        
        do {
            _ = try await withCheckedThrowingContinuation { [weak self] continuation in
                guard let self = self else { return }
                self.continuation = continuation
                let task = s.downloadTask(with: downloadURL)
                self.downloadTask = task
                task.resume()
            }
            
            await MainActor.run {
                updateProgress = 0.8
                updateStatus = "Extracting update..."
            }
            
            // Extract the zip file
            let extractionDir = tempDir.appendingPathComponent("extracted")
            try FileManager.default.createDirectory(at: extractionDir, withIntermediateDirectories: true)
            
            try await ProcessRunner.runChecked(
                "/usr/bin/unzip",
                arguments: ["-o", zipPath.path, "-d", extractionDir.path],
                errorBuilder: { _ in Self.updaterError("Failed to extract the update archive.") }
            )
            
            let fm = FileManager.default
            let appBundle = try Self.findAppBundle(in: extractionDir)
            try Self.validateDownloadedApp(appBundle)
            
            await MainActor.run {
                updateProgress = 0.95
                updateStatus = "Preparing restart..."
            }
            
            let currentAppURL = Bundle.main.bundleURL
            let currentAppPath = currentAppURL.path
            let newAppPath = appBundle.path
            let scriptPath = tempDir.appendingPathComponent("updater.sh").path
            let pid = ProcessInfo.processInfo.processIdentifier
            let quotedCurrentAppPath = Self.shellQuoted(currentAppPath)
            let quotedNewAppPath = Self.shellQuoted(newAppPath)
            let quotedBackupPath = Self.shellQuoted("\(currentAppPath).bak")
            let quotedTempDirPath = Self.shellQuoted(tempDir.path)
            let scriptContent = """
            #!/bin/bash
            exec > /tmp/kafka-launcher-updater.log 2>&1
            set -u

            CURRENT_APP=\(quotedCurrentAppPath)
            NEW_APP=\(quotedNewAppPath)
            BACKUP_PATH=\(quotedBackupPath)
            TEMP_DIR=\(quotedTempDirPath)
            PARENT_PID=\(pid)

            install_update() {
                /bin/rm -rf "$BACKUP_PATH"
                /bin/mv "$CURRENT_APP" "$BACKUP_PATH" || return 1

                if /usr/bin/ditto "$NEW_APP" "$CURRENT_APP"; then
                    /usr/bin/xattr -dr com.apple.quarantine "$CURRENT_APP" 2>/dev/null || true
                    /bin/rm -rf "$BACKUP_PATH"
                    return 0
                fi

                /bin/rm -rf "$CURRENT_APP"
                /bin/mv "$BACKUP_PATH" "$CURRENT_APP" 2>/dev/null || true
                return 1
            }

            install_update_with_admin() {
                ADMIN_SCRIPT="$TEMP_DIR/admin-install.applescript"
                /bin/cat > "$ADMIN_SCRIPT" <<'APPLESCRIPT'
            on run argv
                set currentApp to item 1 of argv
                set newApp to item 2 of argv
                set backupPath to item 3 of argv
                set commandText to "set -e; /bin/rm -rf " & quoted form of backupPath & "; /bin/mv " & quoted form of currentApp & " " & quoted form of backupPath & "; if /usr/bin/ditto " & quoted form of newApp & " " & quoted form of currentApp & "; then /usr/bin/xattr -dr com.apple.quarantine " & quoted form of currentApp & " 2>/dev/null || true; /bin/rm -rf " & quoted form of backupPath & "; else /bin/rm -rf " & quoted form of currentApp & "; /bin/mv " & quoted form of backupPath & " " & quoted form of currentApp & "; exit 1; fi"
                do shell script commandText with administrator privileges
            end run
            APPLESCRIPT
                /usr/bin/osascript "$ADMIN_SCRIPT" "$CURRENT_APP" "$NEW_APP" "$BACKUP_PATH"
            }

            echo "Updater script started. Parent PID: $PARENT_PID"

            # Wait for parent (Kafka Launcher) to exit
            while /bin/kill -0 "$PARENT_PID" 2>/dev/null; do
                sleep 0.2
            done

            echo "Parent process exited. Replacing application bundle..."

            if install_update; then
                echo "Update installed without administrator privileges."
            else
                echo "Normal install failed. Retrying with administrator privileges..."
                if install_update_with_admin; then
                    echo "Update installed with administrator privileges."
                else
                    echo "Privileged install failed."
                    if [ -d "$BACKUP_PATH" ] && [ ! -d "$CURRENT_APP" ]; then
                        /bin/mv "$BACKUP_PATH" "$CURRENT_APP" 2>/dev/null || true
                    fi
                fi
            fi

            # Relaunch the app
            echo "Opening updated application bundle..."
            /usr/bin/open -n "$CURRENT_APP"

            # Clean up temp files
            /bin/rm -rf "$TEMP_DIR"
            echo "Updater script finished."
            """
            
            try scriptContent.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
            
            // Run the script in the background detaching it
            let scriptProcess = Process()
            scriptProcess.executableURL = URL(fileURLWithPath: "/bin/bash")
            scriptProcess.arguments = [scriptPath]
            scriptProcess.standardInput = FileHandle.nullDevice
            scriptProcess.standardOutput = FileHandle.nullDevice
            scriptProcess.standardError = FileHandle.nullDevice
            try scriptProcess.run()
            
            // Exit the current app so the script can proceed
            await MainActor.run {
                updateStatus = "Restarting..."
                updateProgress = 1.0
            }
            
            try await Task.sleep(nanoseconds: 1_000_000_000)
            NSApplication.shared.terminate(nil)
            
        } catch {
            print("Update failed: \(error)")
            await MainActor.run {
                isDownloading = false
                updateStatus = "Update failed: \(error.localizedDescription)"
            }
        }
    }

    private static func preferredAsset(from assets: [ReleaseAsset]) -> ReleaseAsset? {
        let namedAssets = assets.map { (asset: $0, name: $0.name.lowercased()) }
        let zipAssets = namedAssets.filter { $0.name.hasSuffix(".zip") }

        #if arch(arm64)
        let architectureNames = ["applesilicon", "apple-silicon", "arm64", "aarch64"]
        #elseif arch(x86_64)
        let architectureNames = ["intel", "x86_64", "x64", "amd64"]
        #else
        let architectureNames: [String] = []
        #endif

        if let asset = zipAssets.first(where: { item in
            architectureNames.contains(where: { item.name.contains($0) })
        }) {
            return asset.asset
        }

        if let universal = zipAssets.first(where: { $0.name.contains("universal") }) {
            return universal.asset
        }

        return zipAssets.first?.asset ?? namedAssets.first?.asset
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func findAppBundle(in directory: URL) throws -> URL {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        if let appBundle = contents.first(where: { $0.pathExtension == "app" }) {
            return appBundle
        }

        if let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let url as URL in enumerator where url.pathExtension == "app" {
                return url
            }
        }

        throw updaterError("No .app bundle found in the downloaded archive.")
    }

    private static func validateDownloadedApp(_ appURL: URL) throws {
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: infoURL) as? [String: Any] else {
            throw updaterError("The downloaded app bundle is missing Info.plist.")
        }

        guard let currentBundleID = Bundle.main.bundleIdentifier else {
            throw updaterError("The current app bundle identifier is missing.")
        }
        let downloadedBundleID = info["CFBundleIdentifier"] as? String
        guard downloadedBundleID == currentBundleID else {
            throw updaterError("The downloaded app bundle does not match Kafka Launcher.")
        }

        let downloadedVersion = (info["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let currentVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let downloadedVersion,
              downloadedVersion.compare(currentVersion, options: .numeric) == .orderedDescending else {
            throw updaterError("The downloaded app is not newer than the current app.")
        }

        if let minimumSystemVersion = info["LSMinimumSystemVersion"] as? String {
            let currentOS = ProcessInfo.processInfo.operatingSystemVersion
            let currentSystemVersion = "\(currentOS.majorVersion).\(currentOS.minorVersion).\(currentOS.patchVersion)"
            guard minimumSystemVersion.compare(currentSystemVersion, options: .numeric) != .orderedDescending else {
                throw updaterError("The downloaded app requires macOS \(minimumSystemVersion), but this Mac is running macOS \(currentSystemVersion).")
            }
        }
    }

    private static func updaterError(_ message: String) -> NSError {
        NSError(domain: "Updater", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    
    // MARK: - URLSessionDownloadDelegate
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let fm = FileManager.default
        if let dest = self.destinationURL {
            do {
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: dest.path) {
                    try fm.removeItem(at: dest)
                }
                try fm.moveItem(at: location, to: dest)
                
                if let continuation = self.continuation {
                    self.continuation = nil
                    continuation.resume(returning: dest)
                }
            } catch {
                if let continuation = self.continuation {
                    self.continuation = nil
                    continuation.resume(throwing: error)
                }
            }
        } else {
            if let continuation = self.continuation {
                self.continuation = nil
                continuation.resume(returning: location)
            }
        }
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0.0
        
        let downloadedText = ByteCountFormatter.string(fromByteCount: totalBytesWritten, countStyle: .file)
        let totalText = ByteCountFormatter.string(fromByteCount: totalBytesExpectedToWrite, countStyle: .file)
        
        Task { @MainActor in
            self.updateProgress = progress * 0.8
            self.updateStatus = "Downloading: \(downloadedText) / \(totalText)"
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            if let continuation = self.continuation {
                self.continuation = nil
                continuation.resume(throwing: error)
            }
        }
    }
}
