import Foundation

// MARK: - Non-blocking Process Runner
//
// Replaces `process.waitUntilExit()` (blocking, freezes Swift concurrency thread pool)
// with `terminationHandler` + CheckedContinuation → UI never freezes.

enum ProcessRunner {

    /// Runs a preconfigured `Process` and awaits its termination.
    /// Does not block any thread — uses `terminationHandler`.
    @discardableResult
    static func run(_ process: Process, onStart: ((Process) -> Void)? = nil) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            var didResume = false
            let lock = NSLock()
            
            process.terminationHandler = { p in
                lock.lock()
                defer { lock.unlock() }
                if !didResume {
                    didResume = true
                    continuation.resume(returning: p.terminationStatus)
                }
            }
            
            do {
                try process.run()
                onStart?(process)
            } catch {
                lock.lock()
                defer { lock.unlock() }
                if !didResume {
                    didResume = true
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Convenience: creates and runs a process from path + arguments.
    @discardableResult
    static func run(
        _ executablePath: String,
        arguments: [String],
        environment: [String: String]? = nil,
        standardOutput: Any? = nil,
        standardError: Any? = nil
    ) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        if let env = environment { process.environment = env }
        process.standardOutput = standardOutput ?? FileHandle.nullDevice
        process.standardError  = standardError  ?? FileHandle.nullDevice
        return try await run(process)
    }

    /// Runs and captures output (stdout) as Data.
    static func runAndCapture(
        _ executablePath: String,
        arguments: [String],
        environment: [String: String]? = nil
    ) async throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        if let env = environment { process.environment = env }
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        try await run(process)
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return data
    }

    /// Runs and throws if exit code != 0.
    static func runChecked(
        _ executablePath: String,
        arguments: [String],
        environment: [String: String]? = nil,
        errorBuilder: ((Int32) -> Error)? = nil
    ) async throws {
        let code = try await run(executablePath, arguments: arguments, environment: environment)
        if code != 0 {
            let err = errorBuilder?(code) ?? ProcessRunnerError.nonZeroExit(executablePath, code)
            throw err
        }
    }
}

// MARK: - Errors

enum ProcessRunnerError: LocalizedError {
    case nonZeroExit(String, Int32)

    var errorDescription: String? {
        switch self {
        case .nonZeroExit(let cmd, let code):
            return "Process '\((cmd as NSString).lastPathComponent)' exited with code \(code)"
        }
    }
}
