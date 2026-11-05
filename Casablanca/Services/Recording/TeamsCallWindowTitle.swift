import AppKit
import CoreGraphics
import Foundation

/// One titled window of new Teams, as read from the window server.
/// `number` is `kCGWindowNumber`, which grows as windows are created, so a
/// higher number is a newer window.
struct TeamsWindow: Equatable {
    let number: Int
    let title: String
}

/// Reads the name of the running call from new Teams' window titles.
///
/// New Teams gives a call its own window, present from the pre-join screen
/// on, titled `[Meeting join | ]<call name> | <tenant> | <account email>`.
/// The main window has the same shape with a section name (`Chat`,
/// `Calendar`, …) as its first component. For a scheduled meeting the call
/// name equals the calendar subject; for an ad-hoc call it is the person or
/// "Meeting with …". Anything outside that known shape yields nil, so an
/// unexpected format falls back to time-based matching instead of a guess.
enum TeamsCallWindowTitle {
    /// Separator Teams puts between title components.
    static let separator = " | "

    /// First components Teams shows on the pre-join screen, before the call
    /// name. Compared case-insensitively. Add the Dutch-UI token once captured.
    static let preJoinTokens: Set<String> = ["meeting join"]

    /// First components of windows that are not a call: the main window's
    /// sections and Teams' own auxiliary windows (the screen-sharing bar),
    /// English and Dutch UI. Stored lowercased; compared case-insensitively.
    static let nonCallFirstComponents: Set<String> = Set([
        "Activity", "Chat", "Teams", "Calendar", "Calls", "OneDrive", "Files", "Apps", "Copilot",
        "Communities", "Assignments", "Approvals", "Planner", "Shifts", "Settings", "Help",
        "Search", "Notifications", "Sharing control bar",
        "Activiteit", "Agenda", "Oproepen", "Bestanden", "Instellingen", "Zoeken", "Meldingen",
        "Vergaderingen",
    ].map { $0.lowercased() })

    /// The call's name from Teams windows, or nil when no window is a call
    /// window. Several distinct names (a stray pop-out next to the call): the
    /// newest window (highest number) wins, because the call window is opened
    /// last. That is a heuristic, so it is logged when it fires — without the
    /// names, which identify people.
    static func callName(fromWindows windows: [TeamsWindow]) -> String? {
        let named = windows.compactMap { window in
            callName(fromWindowTitle: window.title).map { (number: window.number, name: $0) }
        }
        guard let newest = named.max(by: { $0.number < $1.number }) else { return nil }
        let distinct = Set(named.map(\.name)).count
        if distinct > 1 {
            Log.recording.notice("Teams call title: \(distinct, privacy: .public) distinct call names; newest window wins")
        }
        return newest.name
    }

    /// One title → call name, or nil for main/section windows and titles not
    /// in the known format.
    static func callName(fromWindowTitle title: String) -> String? {
        // 1. Split, trim, drop empty components.
        var components = title
            .components(separatedBy: separator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // 2. The account email and the tenant name before it close every
        //    known title. Without them this is not a format we know.
        guard let last = components.last, last.contains("@") else { return nil }
        components.removeLast(min(2, components.count))

        // 3. The pre-join screen prefixes the call name with a token.
        if let first = components.first, preJoinTokens.contains(first.lowercased()) {
            components.removeFirst()
        }

        // 4. Nothing left: no call name.
        guard let first = components.first else { return nil }

        // 5. A section or auxiliary window, not a call.
        guard !nonCallFirstComponents.contains(first.lowercased()) else { return nil }

        // 6. A meeting subject can itself contain the separator.
        return components.joined(separator: separator)
    }
}

/// Lists the titled windows of new Teams. A protocol so the app's caller can
/// be tested with a fake.
@MainActor
protocol TeamsWindowTitleReading {
    /// All titled com.microsoft.teams2 windows; empty without permission.
    func teamsWindows() -> [TeamsWindow]
}

/// Reads Teams window titles from the window server (`kCGWindowName`).
///
/// Window titles of other apps need Screen Recording, which the app already
/// holds for system-audio capture. Accessibility is never requested from this
/// path, and the permission is only preflighted, which never prompts. The
/// system calls are injected closures so the filtering is testable; the app
/// reads once per call start.
@MainActor
struct CGTeamsWindowTitleReader: TeamsWindowTitleReading {
    /// New Teams. Its helper, WebView and notification-centre processes have
    /// their own bundle IDs and own no call windows; classic Teams is out of
    /// scope.
    nonisolated static let teamsBundleID = "com.microsoft.teams2"

    private let preflight: () -> Bool
    private let teamsPIDs: () -> Set<pid_t>
    private let windowList: () -> [[String: Any]]

    init(
        preflight: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
        teamsPIDs: @escaping () -> Set<pid_t> = { CGTeamsWindowTitleReader.runningTeamsPIDs() },
        windowList: @escaping () -> [[String: Any]] = { CGTeamsWindowTitleReader.allWindows() }
    ) {
        self.preflight = preflight
        self.teamsPIDs = teamsPIDs
        self.windowList = windowList
    }

    /// Exact match only: a prefix match would pick up the helper processes.
    nonisolated static func isTeamsBundleID(_ bundleID: String?) -> Bool {
        bundleID == teamsBundleID
    }

    static func runningTeamsPIDs() -> Set<pid_t> {
        Set(NSWorkspace.shared.runningApplications
            .filter { isTeamsBundleID($0.bundleIdentifier) }
            .map(\.processIdentifier))
    }

    /// Every window on any Space, minimized ones included: a call window can
    /// sit on another Space or be minimized and still be the call.
    static func allWindows() -> [[String: Any]] {
        CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
    }

    func teamsWindows() -> [TeamsWindow] {
        guard preflight() else {
            Log.recording.notice("Teams window titles: no Screen Recording permission; not reading")
            return []
        }
        let pids = teamsPIDs()
        guard !pids.isEmpty else {
            Log.recording.notice("Teams window titles: Teams is not running")
            return []
        }

        // Any layer is kept: during screen sharing the call window becomes a
        // floating panel and the sharing bar sits on layer 19. Telling call
        // windows from the rest is the parser's job, not a layer filter's.
        let owned = windowList().filter { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? Int else { return false }
            return pids.contains(pid_t(pid))
        }
        let windows: [TeamsWindow] = owned.compactMap { info in
            guard let number = info[kCGWindowNumber as String] as? Int,
                  let title = info[kCGWindowName as String] as? String,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return TeamsWindow(number: number, title: title)
        }

        // Counts and layers only. Raw titles hold the account email and chat
        // members' names, so they never reach the log.
        let layers = owned.map { ($0[kCGWindowLayer as String] as? Int).map(String.init) ?? "?" }
        Log.recording.notice(
            "Teams window titles: \(owned.count, privacy: .public) windows, \(windows.count, privacy: .public) titled, layers [\(layers.joined(separator: ","), privacy: .public)]"
        )
        return windows
    }
}
