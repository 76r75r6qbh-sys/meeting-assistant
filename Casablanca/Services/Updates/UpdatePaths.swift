import Foundation

struct UpdatePaths: Sendable {
    let updatesRoot: URL

    var stagingRoot: URL { updatesRoot.appendingPathComponent("staging", isDirectory: true) }
    var logsRoot: URL { updatesRoot.appendingPathComponent("logs", isDirectory: true) }
    var sentinel: URL { updatesRoot.appendingPathComponent("relaunch.sentinel", isDirectory: false) }

    func stagingDirectory(for version: SemanticVersion) -> URL {
        stagingRoot.appendingPathComponent(version.description, isDirectory: true)
    }

    func relaunchScript(at date: Date) -> URL {
        updatesRoot.appendingPathComponent("relaunch-\(Self.timestamp(date)).sh", isDirectory: false)
    }

    func installLog(at date: Date) -> URL {
        logsRoot.appendingPathComponent("install-\(Self.timestamp(date)).log", isDirectory: false)
    }

    static let `default`: UpdatePaths = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return UpdatePaths(updatesRoot: appSupport.appendingPathComponent("Casablanca/Updates", isDirectory: true))
    }()

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date).replacingOccurrences(of: ":", with: "")
    }
}
