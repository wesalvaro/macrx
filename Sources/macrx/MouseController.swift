import AppKit
import ApplicationServices
import CoreGraphics
import MacrxCore

/// Mouse warping and focus-follows-mouse.
@MainActor
final class MouseController {
    /// Called with the current pointer location (AX coordinates) when it moves into a
    /// different region than before. The receiver decides whether that changes focus.
    var onPointerMoved: ((CGPoint) -> Void)?
    /// Called when the primary button is released anywhere (end of a drag).
    var onMouseUp: (() -> Void)?

    private var monitor: Any?
    private var upMonitor: Any?
    private var suppressUntil = Date.distantPast
    private var lastHandled = Date.distantPast
    private let throttle: TimeInterval = 0.08
    private let suppression: TimeInterval = 0.3

    func startFollowing() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }
    }

    func startDragTracking() {
        guard upMonitor == nil else { return }
        upMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            MainActor.assumeIsolated { self?.onMouseUp?() }
        }
    }

    var isPrimaryButtonDown: Bool {
        CGEventSource.buttonState(.combinedSessionState, button: .left)
    }

    func stopFollowing() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Current pointer location in AX coordinates.
    var location: CGPoint { CoordinateSpace.toAX(NSEvent.mouseLocation) }

    /// `true` when any menu (menu-bar pulldown, context menu, status-bar menu) is open on screen.
    static func isMenuOpen() -> Bool {
        let popUpLayer = Int(CGWindowLevelForKey(.popUpMenuWindow))
        if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]],
           list.contains(where: { ($0[kCGWindowLayer as String] as? Int) == popUpLayer }) {
            return true
        }
        return isMenuBarActive()
    }

    /// `true` when the frontmost application has an open/selected menu-bar item (e.g. "File").
    private static func isMenuBarActive() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.05)
        var menuBar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menuBar) == .success,
              let mb = menuBar else { return false }
        let mbEl = mb as! AXUIElement
        AXUIElementSetMessagingTimeout(mbEl, 0.05)
        var sel: CFTypeRef?
        guard AXUIElementCopyAttributeValue(mbEl, kAXSelectedChildrenAttribute as CFString, &sel) == .success,
              let children = sel as? [AXUIElement] else { return false }
        return !children.isEmpty
    }

    /// `true` when no menu is open and one of macrx's own panels is the topmost window at `point`
    /// (AX coordinates), i.e. nothing (menu, popover, dialog…) is covering it there.
    static func isOwnPanelTopmost(at point: CGPoint) -> Bool {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let popUpLayer = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let maxLayer = Int(CGWindowLevelForKey(.screenSaverWindow))
        if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] {
            if list.contains(where: { ($0[kCGWindowLayer as String] as? Int) == popUpLayer }) {
                return false
            }
            for info in list {
                guard let layer = info[kCGWindowLayer as String] as? Int,
                      layer > 0, layer < maxLayer,
                      let pid = info[kCGWindowOwnerPID as String] as? Int32,
                      let b = info[kCGWindowBounds as String] as? [String: CGFloat],
                      let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"],
                      CGRect(x: x, y: y, width: w, height: h).contains(point)
                else { continue }
                if pid != myPID { return false }
                break
            }
        }
        if isMenuBarActive() { return false }
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.05)
        var el: AXUIElement?
        if AXUIElementCopyElementAtPosition(sys, Float(point.x), Float(point.y), &el) == .success,
           let el {
            return el.pid == myPID
        }
        return true
    }

    /// Moves the pointer to `point` (AX coordinates) and suppresses focus-follows-mouse briefly,
    /// so the warp itself never triggers a focus change.
    func warp(to point: CGPoint) {
        suppress()
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// Ignore pointer motion for a short while (after programmatic focus/layout changes).
    func suppress() {
        suppressUntil = Date().addingTimeInterval(suppression)
    }

    /// Synthesizes a left click at `point` (AX coordinates) and puts the pointer back where it was.
    /// Used as a last resort to make a window key in apps that ignore AX/window-server focus.
    func clickAndRestore(at point: CGPoint) {
        let original = location
        suppress()
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
        CGWarpMouseCursorPosition(original)
        CGAssociateMouseAndMouseCursorPosition(1)
        suppress()
    }

    private func pointerMoved() {
        let now = Date()
        if now < suppressUntil {
            // Re-evaluate once the suppression window closes, in case the pointer came to rest
            // over a different window while we were ignoring motion.
            scheduleRecheck(after: suppressUntil.timeIntervalSince(now) + 0.01)
            return
        }
        guard now.timeIntervalSince(lastHandled) >= throttle else {
            scheduleRecheck(after: throttle)
            return
        }
        lastHandled = now
        onPointerMoved?(location)
    }

    private var recheck: DispatchWorkItem?

    private func scheduleRecheck(after delay: TimeInterval) {
        guard recheck == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.recheck = nil
            self.pointerMoved()
        }
        recheck = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}
