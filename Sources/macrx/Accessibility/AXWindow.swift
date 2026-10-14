import AppKit
import ApplicationServices
import MacrxCore

/// Private but long-stable AX symbol that maps a window element to its CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ out: UnsafeMutablePointer<CGWindowID>) -> AXError

extension AXUIElement {
    func attribute<T>(_ name: String, as type: T.Type = T.self) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    func setAttribute(_ name: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(self, name as CFString, value) == .success
    }

    var pid: pid_t {
        var p: pid_t = 0
        AXUIElementGetPid(self, &p)
        return p
    }

    var cgWindowID: CGWindowID? {
        var id: CGWindowID = 0
        guard _AXUIElementGetWindow(self, &id) == .success, id != 0 else { return nil }
        return id
    }
}

/// A window of another application, addressed through the Accessibility API.
struct AXWindow: Hashable {
    let element: AXUIElement
    let id: WindowID

    init?(element: AXUIElement) {
        guard let cg = element.cgWindowID else { return nil }
        self.element = element
        self.id = WindowID(pid: element.pid, cgID: cg)
    }

    static func == (a: AXWindow, b: AXWindow) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    // MARK: Attributes

    var title: String { element.attribute(kAXTitleAttribute) ?? "" }
    var role: String { element.attribute(kAXRoleAttribute) ?? "" }
    var subrole: String { element.attribute(kAXSubroleAttribute) ?? "" }
    var isMinimized: Bool { element.attribute(kAXMinimizedAttribute) ?? false }
    var isStandard: Bool { role == kAXWindowRole && subrole == kAXStandardWindowSubrole }

    /// `true` if the element is still backed by a live window.
    var isAlive: Bool { element.attribute(kAXRoleAttribute, as: String.self) != nil }

    /// `false` for fixed-size windows (Calculator, many utility windows).
    var isResizable: Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &settable) == .success else { return true }
        return settable.boolValue
    }

    var frame: CGRect? {
        guard let posV: AXValue = element.attribute(kAXPositionAttribute),
              let sizeV: AXValue = element.attribute(kAXSizeAttribute)
        else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(posV, .cgPoint, &p)
        AXValueGetValue(sizeV, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    /// Applies `rect` (AX coordinates). Sets size → position → size, which handles apps
    /// that clamp either attribute relative to the other.
    @discardableResult
    func setFrame(_ rect: CGRect) -> Bool {
        var p = rect.origin, s = rect.size
        guard let pv = AXValueCreate(.cgPoint, &p), let sv = AXValueCreate(.cgSize, &s) else { return false }
        _ = element.setAttribute(kAXSizeAttribute, sv)
        let okPos = element.setAttribute(kAXPositionAttribute, pv)
        let okSize = element.setAttribute(kAXSizeAttribute, sv)
        return okPos && okSize
    }

    func setPosition(_ p: CGPoint) {
        var p = p
        if let pv = AXValueCreate(.cgPoint, &p) { _ = element.setAttribute(kAXPositionAttribute, pv) }
    }

    // MARK: Actions

    /// Raise and make this the app's key window.
    func raise() {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        // Main + focused: needed for the app to switch its key window to this one
        // (raising alone only reorders).
        _ = element.setAttribute(kAXMainAttribute, kCFBooleanTrue)
        _ = element.setAttribute(kAXFocusedAttribute, kCFBooleanTrue)
    }

    /// Z-order only: bring to the front of its layer without touching key/main state.
    func orderFront() {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    func unminimize() {
        _ = element.setAttribute(kAXMinimizedAttribute, kCFBooleanFalse)
    }

    /// Presses the window's standard close button (`kAXCloseButtonAttribute`).
    @discardableResult
    func close() -> Bool {
        guard let btn: AXUIElement = element.attribute(kAXCloseButtonAttribute) else { return false }
        return AXUIElementPerformAction(btn, kAXPressAction as CFString) == .success
    }
}
