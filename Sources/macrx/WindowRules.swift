import Foundation
import MacrxCore

enum WindowDisposition {
    case tile, float, ignore
}

/// Decides how a newly seen window should be treated.
struct WindowRules {
    var rules: [Rule]

    func disposition(for window: AXWindow, bundleID: String?) -> WindowDisposition {
        let title = window.title
        for r in rules where r.matches(appID: bundleID, title: title) {
            if r.ignore { return .ignore }
            if r.float { return .float }
        }
        // Dialogs, utility panels, etc. are never tiled.
        guard window.isStandard else { return .float }
        return .tile
    }
}
