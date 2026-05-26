import Foundation

// MARK: - Download Manager (enhanced with archive extraction, verification, chunked downloads)

@Observable
class DownloadManager: NSObject {
    var activeDownloads: [String: DownloadTask] = [:]

    struct DownloadTask: Identifiable {
        let id: String
        let gameType: GameType
        var progress: Double = 0
        var totalBytes: Int64 = 0
        var downloadedBytes: Int64 = 0
        var downloadSpeed: Int64 = 0
        var status: Status = .pending

        enum Status: Equatable {
            case pending, downloading, extracting, verifying, completed, failed(String), paused
        }

        var speedText: String {
            guard downloadedBytes > 0 else { return "" }
            return ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)
                + " / "
                + ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        }

        var speedPerSecond: String {
            guard downloadSpeed > 0 else { return "" }
            return ByteCountFormatter.string(fromByteCount: downloadSpeed, countStyle: .file) + "/s"
        }
    }

    private var _session: URLSession?
    private var session: URLSession {
        if let s = _session { return s }
        let config = URLSessionConfiguration.default
        config.isDiscretionary = false
        config.httpMaximumConnectionsPerHost = 16 // 16 concurrent connections
        let s = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        _session = s
        return s
    }

    private var downloadTasks: [String: URLSessionDownloadTask] = [:]
    private var progressHandlers: [String: (Double) -> Void] = [:]
    private var completionHandlers: [String: (Result<URL, Error>) -> Void] = [:]
    private var destinations: [String: URL] = [:]
    private var lastProgressTime: [String: Date] = [:]
    private var lastProgressBytes: [String: Int64] = [:]

    // MARK: - Download with Progress

    func download(
        url: URL,
        to destination: URL,
        id: String,
        gameType: GameType,
        onProgress: @escaping (Double) -> Void,
        onComplete: @escaping (Result<URL, Error>) -> Void
    ) {
        let task = session.downloadTask(with: url)
        downloadTasks[id] = task
        progressHandlers[id] = onProgress
        completionHandlers[id] = onComplete
        destinations[id] = destination
        activeDownloads[id] = DownloadTask(id: id, gameType: gameType)
        task.resume()
    }

    // MARK: - Download and Extract Archive (for game installation)

    func downloadAndExtract(
        url: URL,
        to extractDir: String,
        id: String,
        gameType: GameType,
        onProgress: @escaping (Double, String) -> Void,
        onComplete: @escaping (Result<Void, Error>) -> Void
    ) {
        download(
            url: url,
            to: URL(fileURLWithPath: NSTemporaryDirectory() + "/" + url.lastPathComponent),
            id: id,
            gameType: gameType,
            onProgress: { progress in
                onProgress(progress * 0.8, "Downloading... \(Int(progress * 100))%")
            },
            onComplete: { [weak self] result in
                switch result {
                case .success(let archiveURL):
                    Task {
                        do {
                            await MainActor.run {
                                self?.activeDownloads[id]?.status = .extracting
                            }
                            onProgress(0.85, "Extracting...")

                            try await self?.extractArchive(
                                at: archiveURL.path,
                                to: extractDir
                            )
                            onProgress(1.0, "Complete")

                            await MainActor.run {
                                self?.activeDownloads[id]?.status = .completed
                            }
                            onComplete(.success(()))
                        } catch {
                            await MainActor.run {
                                self?.activeDownloads[id]?.status = .failed(error.localizedDescription)
                            }
                            onComplete(.failure(error))
                        }
                    }
                case .failure(let error):
                    onComplete(.failure(error))
                }
            }
        )
    }

    // MARK: - Archive Extraction

    func extractArchive(at archivePath: String, to destination: String) async throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: destination, withIntermediateDirectories: true)

        let ext = archivePath.lowercased()
        let process = Process()

        if ext.hasSuffix(".zip") {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-o", archivePath, "-d", destination]
        } else if ext.hasSuffix(".tar.xz") || ext.hasSuffix(".txz") {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["xJf", archivePath, "-C", destination]
        } else if ext.hasSuffix(".tar.gz") || ext.hasSuffix(".tgz") {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["xzf", archivePath, "-C", destination]
        } else if ext.hasSuffix(".7z") {
            // Try 7z from homebrew
            let sevenZip = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/7z")
                ? "/opt/homebrew/bin/7z" : "/usr/local/bin/7z"
            process.executableURL = URL(fileURLWithPath: sevenZip)
            process.arguments = ["x", archivePath, "-o" + destination, "-y"]
        } else {
            // Default: try tar
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["xf", archivePath, "-C", destination]
        }

        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try await ProcessRunner.runChecked(
            process.executableURL!.path,
            arguments: process.arguments ?? [],
            errorBuilder: { _ in DownloadError.extractionFailed(archivePath) }
        )

        // Clean up archive
        try? fm.removeItem(atPath: archivePath)
    }

    // MARK: - File Verification (MD5)

    func verifyFile(at path: String, expectedMD5: String) -> Bool {
        PatchManager.md5OfFile(atPath: path).lowercased() == expectedMD5.lowercased()
    }

    // MARK: - Cancel / Pause / Resume

    func cancel(id: String) {
        downloadTasks[id]?.cancel()
        cleanup(id: id)
    }

    func pause(id: String) {
        downloadTasks[id]?.cancel(byProducingResumeData: { [weak self] data in
            // Store resume data if needed
            DispatchQueue.main.async {
                self?.activeDownloads[id]?.status = .paused
            }
        })
    }

    // MARK: - Errors

    enum DownloadError: LocalizedError {
        case extractionFailed(String)
        case verificationFailed(String)

        var errorDescription: String? {
            switch self {
            case .extractionFailed(let f): return "Failed to extract: \(f)"
            case .verificationFailed(let f): return "File verification failed: \(f)"
            }
        }
    }
}

// MARK: - URLSession Delegate

extension DownloadManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let id = downloadTasks.first(where: { $0.value == downloadTask })?.key else { return }

        // Move to destination if set
        if let dest = destinations[id] {
            let fm = FileManager.default
            try? fm.createDirectory(
                at: dest.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? fm.removeItem(at: dest)
            try? fm.moveItem(at: location, to: dest)

            DispatchQueue.main.async {
                self.activeDownloads[id]?.status = .completed
                self.completionHandlers[id]?(.success(dest))
                self.cleanup(id: id)
            }
        } else {
            DispatchQueue.main.async {
                self.activeDownloads[id]?.status = .completed
                self.completionHandlers[id]?(.success(location))
                self.cleanup(id: id)
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTasks.first(where: { $0.value == downloadTask })?.key else { return }
        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0

        // Calculate speed
        let now = Date()
        var speed: Int64 = 0
        if let lastTime = lastProgressTime[id], let lastBytes = lastProgressBytes[id] {
            let elapsed = now.timeIntervalSince(lastTime)
            if elapsed > 0.5 {
                speed = Int64(Double(totalBytesWritten - lastBytes) / elapsed)
                lastProgressTime[id] = now
                lastProgressBytes[id] = totalBytesWritten
            }
        } else {
            lastProgressTime[id] = now
            lastProgressBytes[id] = totalBytesWritten
        }

        DispatchQueue.main.async {
            self.activeDownloads[id]?.progress = progress
            self.activeDownloads[id]?.downloadedBytes = totalBytesWritten
            self.activeDownloads[id]?.totalBytes = totalBytesExpectedToWrite
            self.activeDownloads[id]?.downloadSpeed = speed
            self.activeDownloads[id]?.status = .downloading
            self.progressHandlers[id]?(progress)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error,
              let id = downloadTasks.first(where: { $0.value == task })?.key else { return }
        DispatchQueue.main.async {
            self.activeDownloads[id]?.status = .failed(error.localizedDescription)
            self.completionHandlers[id]?(.failure(error))
            self.cleanup(id: id)
        }
    }

    private func cleanup(id: String) {
        downloadTasks.removeValue(forKey: id)
        progressHandlers.removeValue(forKey: id)
        completionHandlers.removeValue(forKey: id)
        destinations.removeValue(forKey: id)
        activeDownloads.removeValue(forKey: id)
        lastProgressTime.removeValue(forKey: id)
        lastProgressBytes.removeValue(forKey: id)
    }
}
