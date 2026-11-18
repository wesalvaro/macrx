import Foundation
import MacrxCore

enum WindowDisposition {
    case tile, float, ignore
}

/// Decides how a newly seen window should be treated.
///
/// Everything is tiled by default. Floating is strictly opt-in: a `[[rule]]` with
/// `float = true`, or the user toggling it at runtime. (Windows that aren't real
/// windows — sheets, popovers, menus — never reach this point; `WindowWatcher` only
/// tracks elements with the `AXWindow` role.)
struct WindowRules {
    var rules: [Rule]

    func disposition(for window: AXWindow, bundleID: String?) -> WindowDisposition {
        let title = window.title
        for r in rules where r.matches(appID: bundleID, title: title) {
            if r.ignore { return .ignore }
            if r.float { return .float }
        }
        return .tile
    }

    /// The workspace a new window should open on, from the first matching rule that sets one.
    func assignedWorkspace(for window: AXWindow, bundleID: String?) -> Int? {
        let title = window.title
        return rules.first { $0.workspace != nil && $0.matches(appID: bundleID, title: title) }?.workspace
    }

    func clickToFocus(bundleID: String?, title: String) -> Bool {
        rules.contains { $0.clickToFocus && $0.matches(appID: bundleID, title: title) }
    }
}
