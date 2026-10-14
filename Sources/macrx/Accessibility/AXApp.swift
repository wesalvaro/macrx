import AppKit
import ApplicationServices
import MacrxCore

/// An application addressed through the Accessibility API.
struct AXApp {
    let pid: pid_t
    let element: AXUIElement
    let runningApp: NSRunningApplication

    init?(_ app: NSRunningApplication) {
        guard app.activationPolicy == .regular, !app.isTerminated else { return nil }
        pid = app.processIdentifier
        element = AXUIElementCreateApplication(pid)
        runningApp = app
    }

    var bundleID: String? { runningApp.bundleIdentifier }
    var name: String { runningApp.localizedName ?? bundleID ?? "pid \(pid)" }
    var icon: NSImage? { runningApp.icon }

    var windows: [AXWindow] {
        let elements: [AXUIElement] = element.attribute(kAXWindowsAttribute) ?? []
        return elements.compactMap(AXWindow.init(element:))
    }

    var focusedWindow: AXWindow? {
        guard let e: AXUIElement = element.attribute(kAXFocusedWindowAttribute) else { return nil }
        return AXWindow(element: e)
    }

    func activate() {
        runningApp.activate(options: [.activateIgnoringOtherApps])
    }
}
