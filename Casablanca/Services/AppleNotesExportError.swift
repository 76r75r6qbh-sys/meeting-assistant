import Foundation

enum AppleNotesExportError: LocalizedError, Equatable {
    case permissionDenied
    case timedOut
    case scriptingFailed(code: Int, message: String)
    case unexpectedResponse(String)

    static func from(appleScriptErrorCode code: Int, message: String = "") -> AppleNotesExportError {
        switch code {
        case -1743, -1744, -600, -10810:
            return .permissionDenied
        default:
            return .scriptingFailed(code: code, message: message)
        }
    }

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Casablanca isn't allowed to control Notes. Enable it under System Settings → Privacy & Security → Automation → Casablanca → Notes, then try again."
        case .timedOut:
            return "The Apple Notes export timed out. Try again or check that Notes is responsive."
        case .scriptingFailed(let code, let message):
            return "Apple Notes export failed (\(code)): \(message)"
        case .unexpectedResponse(let detail):
            return "Apple Notes returned an unexpected response: \(detail)"
        }
    }
}
