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
            
            struct Release: Codable {
                let tag_name: String
                let body: String?
                let html_url: String
                struct Asset: Codable {
                    let name: String
                    let browser_download_url: String
                }
                let assets: [Asset]
            }
            
            let release = try JSONDecoder().decode(Release.self, from: data)
            let latestVer = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).trimmingCharacters(in: .whitespacesAndNewlines)
            let currentVer = currentVersion.trimmingCharacters(in: .whitespacesAndNewlines)
            
            let isNewer = latestVer.compare(currentVer, options: .numeric) == .orderedDescending
            
            await MainActor.run {
                self.isChecking = false
                self.latestVersion = latestVer
                self.releaseNotes = release.body
                if isNewer {
                    if let zipAsset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".zip") }) {
                        self.downloadURL = URL(string: zipAsset.browser_download_url)
                    } else if let firstAsset = release.assets.first {
                        self.downloadURL = URL(string: firstAsset.browser_download_url)
                    }
                    self.updateAvailable = true
                    self.updateStatus = "New version \(latestVer) is available."
                    if prompt {
                        self.showUpdatePrompt = true
                    }
                } else {
                    self.updateAvailable = false
                    self.updateStatus = "Kafka Launcher is up to date."
                }
            }
            return isNewer
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
        
        do {
            let localURL: URL = try await withCheckedThrowingContinuation { [weak self] continuation in
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
            
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            
            let zipPath = tempDir.appendingPathComponent("update.zip")
            try FileManager.default.moveItem(at: localURL, to: zipPath)
            
            // Extract the zip file
            let extractionDir = tempDir.appendingPathComponent("extracted")
            try FileManager.default.createDirectory(at: extractionDir, withIntermediateDirectories: true)
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-o", zipPath.path, "-d", extractionDir.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try await ProcessRunner.run(process)
            
            let fm = FileManager.default
            let contents = try fm.contentsOfDirectory(at: extractionDir, includingPropertiesForKeys: nil)
            guard let appBundle = contents.first(where: { $0.pathExtension == "app" }) else {
                throw NSError(domain: "Updater", code: 404, userInfo: [NSLocalizedDescriptionKey: "No .app bundle found in the downloaded archive."])
            }
            
            await MainActor.run {
                updateProgress = 0.95
                updateStatus = "Preparing restart..."
            }
            
            let currentAppURL = Bundle.main.bundleURL
            let currentAppPath = currentAppURL.path
            let newAppPath = appBundle.path
            let scriptPath = tempDir.appendingPathComponent("updater.sh").path
            
            let pid = ProcessInfo.processInfo.processIdentifier
            let scriptContent = """
            #!/bin/bash
            # Wait for parent (Kafka Launcher) to exit
            while kill -0 \(pid) 2>/dev/null; do
                sleep 0.2
            done

            # Replace the app safely
            BACKUP_PATH="\(currentAppPath).bak"
            rm -rf "$BACKUP_PATH"
            mv "\(currentAppPath)" "$BACKUP_PATH"

            if cp -R "\(newAppPath)" "\(currentAppPath)"; then
                rm -rf "$BACKUP_PATH"
            else
                # Rollback
                mv "$BACKUP_PATH" "\(currentAppPath)"
            fi

            # Remove macOS quarantine attribute and restore original file permissions
            /usr/bin/xattr -dr com.apple.quarantine "\(currentAppPath)" 2>/dev/null

            # Relaunch the app
            open "\(currentAppPath)"

            # Clean up temp files
            rm -rf "\(tempDir.path)"
            """
            
            try scriptContent.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
            
            // Run the script in the background detaching it
            let scriptProcess = Process()
            scriptProcess.executableURL = URL(fileURLWithPath: "/bin/bash")
            scriptProcess.arguments = [scriptPath]
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
    
    // MARK: - URLSessionDownloadDelegate
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let continuation = self.continuation {
            self.continuation = nil
            continuation.resume(returning: location)
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
