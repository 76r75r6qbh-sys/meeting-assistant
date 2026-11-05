import AppKit
import CoreGraphics
import Foundation
import os

/// One titled window of new Teams, as read from the window server.
/// `number` is `kCGWindowNumber`, which grows as windows are created, so a
/// higher number is a newer window.
struct TeamsWindow: Equatable {
    let number: Int
    let title: String
}

/// One Teams call window: its window number (higher is newer), the call name
/// its title carries, and whether it is the pre-join screen ("Meeting join").
/// The number identifies the call window across reads, so a renamed call is
/// not mistaken for a new one.
struct TeamsCallWindowName: Equatable {
    let number: Int
    let name: String
    let isPreJoin: Bool
}

/// Reads the name of the running call from new Teams' window titles.
///
/// New Teams gives a call its own window, present from the pre-join screen
/// on, titled `[Meeting join | ]<call name> | <tenant> | <account email>`.
/// The main window has the same shape with a section name (`Chat`,
/// `Calendar`, …) as its first component. For a scheduled meeting the call
/// name equals the calendar subject; for an ad-hoc call it is the person or
/// "Meeting with …". Anything outside that known shape yields nil, so an
/// unexpected format falls back to time-based matching instead of a guess. So
/// does a generic placeholder such as "Microsoft Teams meeting", which Teams
/// shows during an external meeting's pre-join.
enum TeamsCallWindowTitle {
    /// Separator Teams puts between title components.
    static let separator = " | "

    /// First components Teams puts in front of the call name: the pre-join
    /// screen ("Meeting join") and the shared-content pop-out ("Shared
    /// content"). Stored lowercased; compared case-insensitively. Add the
    /// Dutch-UI tokens once captured.
    static let preJoinTokens: Set<String> = ["meeting join", "shared content"]

    /// The tokens among `preJoinTokens` that mark the pre-join screen itself,
    /// before the call is joined. The shared-content pop-out is in the call.
    static let preJoinScreenTokens: Set<String> = ["meeting join"]

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

    /// Names Teams shows instead of the meeting subject (an external
    /// meeting's pre-join screen, English and Dutch UI). They name no meeting,
    /// so they count as no name. Stored normalized like event titles
    /// (`TeamsAutoRecordPolicy.normalizedTitle`), so case, spacing and
    /// punctuation ("Teams-vergadering") don't matter.
    /// Covers the English and Dutch Teams UI only; other UI languages need
    /// their own strings added once captured.
    static let placeholderCallNames: Set<String> = Set([
        "Microsoft Teams meeting", "Microsoft Teams-vergadering", "Microsoft Teams vergadering",
        "Teams meeting", "Teams-vergadering", "Meeting", "Vergadering",
    ].map(TeamsAutoRecordPolicy.normalizedTitle))

    /// Whether `name` is one of Teams' generic placeholders rather than the
    /// call's own name.
    static func isPlaceholderCallName(_ name: String) -> Bool {
        placeholderCallNames.contains(TeamsAutoRecordPolicy.normalizedTitle(name))
    }

    /// Every call window among the Teams windows, newest (highest number)
    /// first, one entry per window: a call and its shared-content pop-out
    /// are two entries with the same name. Empty when no window is a call
    /// window.
    static func callWindows(fromWindows windows: [TeamsWindow]) -> [TeamsCallWindowName] {
        windows.sorted(by: { $0.number > $1.number }).compactMap { window in
            parse(windowTitle: window.title).map {
                TeamsCallWindowName(number: window.number, name: $0.name, isPreJoin: $0.isPreJoin)
            }
        }
    }

    /// Every distinct call name in the Teams windows, newest window (highest
    /// number) first; empty when no window is a call window. The call window
    /// is usually opened last, but a stray pop-out can be newer, so the
    /// policy tries every name against the calendar before falling back to
    /// the newest.
    static func callNames(fromWindows windows: [TeamsWindow]) -> [String] {
        callNames(from: callWindows(fromWindows: windows))
    }

    /// The distinct names of `callWindows`, in their (newest-first) order.
    /// Names are deduplicated on their normalized form
    /// (`TeamsAutoRecordPolicy.normalizedTitle`), keeping the newest window's
    /// spelling.
    static func callNames(from callWindows: [TeamsCallWindowName]) -> [String] {
        var seen: Set<String> = []
        return callWindows.map(\.name).filter {
            seen.insert(TeamsAutoRecordPolicy.normalizedTitle($0)).inserted
        }
    }

    /// One title → call name, or nil for main/section windows, placeholders
    /// and titles not in the known format.
    static func callName(fromWindowTitle title: String) -> String? {
        parse(windowTitle: title)?.name
    }

    /// `callName(fromWindowTitle:)`, plus whether the title is the pre-join
    /// screen's.
    private static func parse(windowTitle title: String) -> (name: String, isPreJoin: Bool)? {
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
        var isPreJoin = false
        if let first = components.first?.lowercased(), preJoinTokens.contains(first) {
            isPreJoin = preJoinScreenTokens.contains(first)
            components.removeFirst()
        }

        // 4. Nothing left: no call name.
        guard let first = components.first else { return nil }

        // 5. A section or auxiliary window, not a call.
        guard !nonCallFirstComponents.contains(first.lowercased()) else { return nil }

        // 6. A placeholder instead of the subject says nothing about the call.
        //    Any placeholder component counts, not only the whole name: an
        //    unknown pre-join token (another UI language) can sit in front
        //    of it. A real subject with a placeholder component is lost to
        //    time-based matching, which is accepted.
        guard !components.contains(where: isPlaceholderCallName) else { return nil }

        // 7. A meeting subject can itself contain the separator.
        return (components.joined(separator: separator), isPreJoin)
    }
}

/// Lists the titled windows of new Teams. A protocol so the app's caller can
/// be tested with a fake.
@MainActor
protocol TeamsWindowTitleReading {
    /// All titled com.microsoft.teams2 windows; empty without permission.
    /// `isPeriodic` marks the reads repeated during a call, which log at
    /// debug level instead of notice.
    func teamsWindows(isPeriodic: Bool) -> [TeamsWindow]
}

extension TeamsWindowTitleReading {
    /// A one-off read (a call start), logged at notice level.
    func teamsWindows() -> [TeamsWindow] { teamsWindows(isPeriodic: false) }
}

/// Reads Teams window titles from the window server (`kCGWindowName`).
///
/// Window titles of other apps need Screen Recording, which the app already
/// holds for system-audio capture. Accessibility is never requested from this
/// path, and the permission is only preflighted, which never prompts. The
/// system calls are injected closures so the filtering is testable; the app
/// reads at a call start and, with auto-record on, every 10 s during a call.
@MainActor
struct CGTeamsWindowTitleReader: TeamsWindowTitleReading {
    /// New Teams. Its helper, WebView and notification-centre processes have
    /// their own bundle IDs and own no call windows; classic Teams is out of
    /// scope.
    nonisolated static let teamsBundleID = "com.microsoft.teams2"

    private let preflight: @MainActor () -> Bool
    private let teamsPIDs: @MainActor () -> Set<pid_t>
    private let windowList: @MainActor () -> [[String: Any]]

    init(
        preflight: @escaping @MainActor () -> Bool = { CGPreflightScreenCaptureAccess() },
        teamsPIDs: @escaping @MainActor () -> Set<pid_t> = { CGTeamsWindowTitleReader.runningTeamsPIDs() },
        windowList: @escaping @MainActor () -> [[String: Any]] = { CGTeamsWindowTitleReader.allWindows() }
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

    func teamsWindows(isPeriodic: Bool) -> [TeamsWindow] {
        let level: OSLogType = isPeriodic ? .debug : .default  // .default is notice
        guard preflight() else {
            Log.recording.log(level: level, "Teams window titles: no Screen Recording permission; not reading")
            return []
        }
        let pids = teamsPIDs()
        guard !pids.isEmpty else {
            Log.recording.log(level: level, "Teams window titles: Teams is not running")
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
        Log.recording.log(
            level: level,
            "Teams window titles: \(owned.count, privacy: .public) windows, \(windows.count, privacy: .public) titled, layers [\(layers.joined(separator: ","), privacy: .public)]"
        )
        return windows
    }
}
