import AppKit
import ObjectiveC

/// Counts the exact re-dirtying behind the 0.16.0 crash: a NavigationSplitView
/// column publishing a new minimum size *while* the window is inside its own
/// Update Constraints pass. In the crash report that path is
/// `NSHostingView.SizeConstraints.update(from:)` →
/// `SplitViewChildController.hostingView(_:didUpdateMinSize:maxSize:)` →
/// `-[NSView setNeedsUpdateConstraints:]` →
/// `-[NSWindow _postWindowNeedsUpdateConstraints]`, and AppKit aborts once a
/// window needs more passes than it has views.
///
/// It swizzles that private AppKit method plus the public
/// `-[NSWindow updateConstraintsIfNeeded]`, and attributes a post to a split
/// column by its call stack. Test-only; AppKit/SwiftUI internals may change
/// between macOS releases, so callers must check `isInstalled` and run a
/// control that proves the probe still observes the path.
///
/// Only the `target` window is observed: the test host is the real app, whose
/// own main window runs display cycles while a test pumps the run loop.
@MainActor
enum SplitColumnMinimumSizeProbe {
    private(set) static var isInstalled = false

    nonisolated(unsafe) private static weak var target: NSWindow?
    nonisolated(unsafe) private static var passDepth = 0
    nonisolated(unsafe) private static var count = 0
    private static var didAttemptInstall = false

    /// Starts counting, from zero, for `window` only.
    static func observe(_ window: NSWindow) {
        target = window
        passDepth = 0
        count = 0
    }

    /// Column-minimum-size posts seen during the target's constraint passes
    /// since `observe(_:)`.
    static var redirtyCount: Int { count }

    static func install() {
        guard !didAttemptInstall else { return }
        didAttemptInstall = true

        typealias Imp = @convention(c) (AnyObject, Selector) -> Void

        let postSelector = NSSelectorFromString("_postWindowNeedsUpdateConstraints")
        let passSelector = #selector(NSWindow.updateConstraintsIfNeeded)
        guard let postMethod = class_getInstanceMethod(NSWindow.self, postSelector),
              let passMethod = class_getInstanceMethod(NSWindow.self, passSelector)
        else { return }

        let originalPost = unsafeBitCast(method_getImplementation(postMethod), to: Imp.self)
        let post: @convention(block) (AnyObject) -> Void = { window in
            if window === target, passDepth > 0,
               Thread.callStackSymbols.contains(where: { $0.contains("SplitViewChildController") }) {
                count += 1
            }
            originalPost(window, postSelector)
        }
        method_setImplementation(postMethod, imp_implementationWithBlock(post))

        let originalPass = unsafeBitCast(method_getImplementation(passMethod), to: Imp.self)
        let pass: @convention(block) (AnyObject) -> Void = { window in
            guard window === target else {
                originalPass(window, passSelector)
                return
            }
            passDepth += 1
            originalPass(window, passSelector)
            passDepth -= 1
        }
        method_setImplementation(passMethod, imp_implementationWithBlock(pass))

        isInstalled = true
    }
}
