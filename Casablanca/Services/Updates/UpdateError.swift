import Foundation

enum UpdateError: LocalizedError, Equatable {
    case notInApplicationsFolder
    case checkFailed(URLError)
    case rateLimited(retryAfter: Date)
    case malformedResponse
    case assetNotFound
    case notSafeToQuit(reason: String)
    case downloadFailed(URLError)
    case unzipFailed
    case quarantineStripFailed(String)
    case versionRegression
    case codesignFailed
    case swapFailed(String)
    case helperSpawnFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInApplicationsFolder:
            return "Move Casablanca to /Applications to enable updates."
        case .checkFailed(let urlError):
            return "Could not reach GitHub: \(urlError.localizedDescription)"
        case .rateLimited(let retryAfter):
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return "GitHub rate limit hit. Try again after \(formatter.string(from: retryAfter))."
        case .malformedResponse:
            return "Unexpected response from GitHub."
        case .assetNotFound:
            return "No macOS asset was found in the latest release."
        case .notSafeToQuit(let reason):
            return "Casablanca is busy with \(reason). Finish or stop it, then click Install again."
        case .downloadFailed(let urlError):
            return "Update download failed: \(urlError.localizedDescription)"
        case .unzipFailed:
            return "Update download was corrupt."
        case .quarantineStripFailed(let detail):
            return "Could not prepare the update for installation. (\(detail))"
        case .versionRegression:
            return "Update package was older than the current version. Cancelling."
        case .codesignFailed:
            return "Update package was corrupt. Update was not installed."
        case .swapFailed(let detail):
            return "Could not install the update. Your existing app is unchanged. (\(detail))"
        case .helperSpawnFailed(let detail):
            return "Update was installed but Casablanca could not relaunch automatically. Please reopen Casablanca. (\(detail))"
        }
    }

    static func == (lhs: UpdateError, rhs: UpdateError) -> Bool {
        switch (lhs, rhs) {
        case (.notInApplicationsFolder, .notInApplicationsFolder): return true
        case (.checkFailed(let l), .checkFailed(let r)): return l.code == r.code
        case (.rateLimited(let l), .rateLimited(let r)): return l == r
        case (.malformedResponse, .malformedResponse): return true
        case (.assetNotFound, .assetNotFound): return true
        case (.notSafeToQuit(let l), .notSafeToQuit(let r)): return l == r
        case (.downloadFailed(let l), .downloadFailed(let r)): return l.code == r.code
        case (.unzipFailed, .unzipFailed): return true
        case (.quarantineStripFailed(let l), .quarantineStripFailed(let r)): return l == r
        case (.versionRegression, .versionRegression): return true
        case (.codesignFailed, .codesignFailed): return true
        case (.swapFailed(let l), .swapFailed(let r)): return l == r
        case (.helperSpawnFailed(let l), .helperSpawnFailed(let r)): return l == r
        default: return false
        }
    }
}
