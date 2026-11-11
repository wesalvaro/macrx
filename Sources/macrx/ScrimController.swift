import AppKit
import MacrxCore

/// Keeps one translucent scrim panel per display, ordered directly behind the visible
/// workspace's foreground windows (and above hidden workspaces' windows and non-top stack
/// members).
@MainActor
final class ScrimController {
    private var panels: [DisplayID: ScrimPanel] = [:]

    /// Updates each display's scrim frame and orders it immediately below `belowWindow`
    /// (the lowest foreground window on that display), or at the front of the normal window
    /// layer when the visible workspace on that display has no foreground windows.
    func sync(displays: [(id: DisplayID, frame: CGRect, belowWindow: CGWindowID?)]) {
        var seen: Set<DisplayID> = []
        for d in displays {
            seen.insert(d.id)
            let panel = panels[d.id] ?? ScrimPanel()
            panels[d.id] = panel
            let rect = CoordinateSpace.toAppKit(d.frame)
            if panel.frame != rect { panel.setFrame(rect, display: true) }
            if let below = d.belowWindow {
                panel.order(.below, relativeTo: Int(below))
            } else {
                panel.orderFrontRegardless()
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
