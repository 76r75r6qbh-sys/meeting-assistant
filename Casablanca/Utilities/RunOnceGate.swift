import Foundation

/// Lets one piece of work through exactly once per instance. `AppModel.bootstrap`
/// is driven from the main window's `.task`, and that task runs again every time
/// the window is reopened from the menu bar. Without the gate each reopen re-ran
/// launch housekeeping (deleting a staged update the UI was offering to install),
/// stacked another `willTerminate` observer, re-installed the notification
/// delegate and re-ran the recovery sweeps.
struct RunOnceGate {
    private(set) var hasRun = false

    /// `true` the first time it is called, `false` on every call after.
    mutating func claim() -> Bool {
        guard !hasRun else { return false }
        hasRun = true
        return true
    }
}
