import AppKit
import MacrxCore

/// Keeps one translucent scrim panel per display, ordered directly behind the visible
/// workspace's foreground windows (and above hidden workspaces' windows and non-top stack
/// members).
@MainActor
final class ScrimController {
    enum Ordering: Equatable {
        /// Place immediately above the topmost background window on this display.
        case above(CGWindowID)
        /// Place immediately below the bottommost foreground window on this display.
        case below(CGWindowID)
        /// Place at the front of the normal window layer (empty visible workspace).
        case front
        /// Hide the scrim (empty visible workspace with no background windows on this display).
        case hidden
    }

    struct Entry {
        let id: DisplayID
        let frame: CGRect
        let ordering: Ordering
    }

    private var panels: [DisplayID: ScrimPanel] = [:]

    /// Updates each display's scrim frame and z-order between the display's foreground and
    /// background windows.
    func sync(displays: [Entry]) {
        var seen: Set<DisplayID> = []
        for d in displays {
            seen.insert(d.id)
            let panel = panels[d.id] ?? ScrimPanel()
            panels[d.id] = panel
            let rect = CoordinateSpace.toAppKit(d.frame)
            if panel.frame != rect { panel.setFrame(rect, display: true) }
            switch d.ordering {
            case .above(let windowID):
                panel.order(.above, relativeTo: Int(windowID))
            case .below(let windowID):
                panel.order(.below, relativeTo: Int(windowID))
            case .front:
                panel.orderFrontRegardless()
            case .hidden:
                panel.orderOut(nil)
            }
        }
        for (id, panel) in panels where !seen.contains(id) {
            panel.orderOut(nil)
            panels[id] = nil
        }
    }

    func hideAll() {
        panels.values.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }
}

private final class ScrimPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .normal
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = NSColor.black.withAlphaComponent(0.45)
        hasShadow = false
        ignoresMouseEvents = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        contentView = ScrimView()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // Never let AppKit's automatic click-ordering bring the scrim in front of the windows
    // it sits behind; `ScrimController` orders it explicitly via `order(_:relativeTo:)` or
    // `orderFrontRegardless()`.
    override func orderFront(_ sender: Any?) {}
}

private final class ScrimView: NSView {
    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
    override func mouseDown(with event: NSEvent) {
        NSApp.preventWindowOrdering()
    }
}
