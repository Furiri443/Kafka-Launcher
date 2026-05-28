import Foundation

// MARK: - Game State

enum GameState: Equatable {
    case notInstalled
    case checkingForUpdates
    case installing(progress: Double, status: String)
    case updating(progress: Double, status: String)
    case ready
    case needsUpdate(currentVersion: String, latestVersion: String)
    case launching
    case running
    case error(message: String)

    var isActionable: Bool {
        switch self {
        case .notInstalled, .ready, .needsUpdate, .error: return true
        default: return false
        }
    }

    var isBusy: Bool {
        switch self {
        case .checkingForUpdates, .installing, .updating, .launching: return true
        default: return false
        }
    }

    var actionLabel: String {
        switch self {
        case .notInstalled: return "Install"
        case .checkingForUpdates: return "Checking..."
        case .installing(let p, _): return "Installing \(Int(p * 100))%"
        case .updating(let p, _): return "Updating \(Int(p * 100))%"
        case .ready: return "Launch"
        case .needsUpdate: return "Update"
        case .launching: return "Launching..."
        case .running: return "Running"
        case .error: return "Retry"
        }
    }

    var progress: Double? {
        switch self {
        case .installing(let p, _), .updating(let p, _): return p
        default: return nil
        }
    }

    var statusText: String? {
        switch self {
        case .installing(_, let s), .updating(_, let s): return s
        case .error(let m): return m
        default: return nil
        }
    }
}
