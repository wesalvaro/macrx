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

    /// `nil` when the app did not answer (asleep / hung / busy); `[]` only when it really has
    /// no windows. Use this wherever "no windows" would trigger destructive bookkeeping.
    var windowsIfResponsive: [AXWindow]? {
        guard case .success(let elements) = element.attributeResult(kAXWindowsAttribute, as: [AXUIElement].self)
        else { return nil }
        return (elements ?? []).compactMap(AXWindow.init(element:))
    }

    var focusedWindow: AXWindow? {
        guard let e: AXUIElement = element.attribute(kAXFocusedWindowAttribute) else { return nil }
        return AXWindow(element: e)
    }

    func activate() {
        // Since macOS 14, `NSRunningApplication.activate()` from a background process is
        // mostly ignored. Setting the AX frontmost attribute is honored for trusted processes.
        _ = element.setAttribute(kAXFrontmostAttribute, kCFBooleanTrue)
        runningApp.activate()
    }
}
