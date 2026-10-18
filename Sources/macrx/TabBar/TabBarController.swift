import AppKit
import MacrxCore

/// Keeps one `TabBarPanel` per visible tile that has a tab bar, plus a drop-preview panel
/// during tab drag operations.
@MainActor
final class TabBarController {
    var onTabClicked: ((WindowID) -> Void)?
    var onTabClosed: ((WindowID) -> Void)?
    var menuForTab: ((WindowID) -> NSMenu?)?
    var onDragUpdated: ((WindowID, CGPoint) -> Void)?
    var onDragEnded: ((WindowID, CGPoint) -> Void)?
    var fontSize: CGFloat = 12

    private var panels: [ObjectIdentifier: TabBarPanel] = [:]
    private lazy var dropPreview = DropPreviewPanel()

    /// Tab bar frames (AX coordinates) per stack, for pointer hit-testing.
    private(set) var frames: [ObjectIdentifier: CGRect] = [:]
    /// Per-stack tab rects (AX coordinates), in window order.
    private(set) var tabRects: [ObjectIdentifier: [CGRect]] = [:]
    /// Per-stack close-button rects (AX coordinates), in window order.
    private(set) var closeRects: [ObjectIdentifier: [CGRect]] = [:]
    private var tabWindows: [ObjectIdentifier: [WindowID]] = [:]

    func sync(tiles: [Tile], focused: WindowID?, item: (WindowID) -> TabItem) {
        var seen: Set<ObjectIdentifier> = []
        frames.removeAll(keepingCapacity: true)
        tabRects.removeAll(keepingCapacity: true)
        closeRects.removeAll(keepingCapacity: true)
        tabWindows.removeAll(keepingCapacity: true)
        for tile in tiles where tile.hasTabBar {
            seen.insert(tile.stackID)
            let panel = panels[tile.stackID] ?? makePanel(for: tile.stackID)
            let view = panel.tabView
            let rect = CoordinateSpace.toAppKit(tile.tabBar)
            if panel.frame != rect { panel.setFrame(rect, display: false) }
            view.fontSize = fontSize
            view.items = tile.windows.map(item)
            view.topID = tile.top
            view.isFocused = focused.map(tile.windows.contains) ?? false
            view.layoutSubtreeIfNeeded()
            frames[tile.stackID] = tile.tabBar
            tabRects[tile.stackID] = view.tabRects.map {
                CGRect(x: tile.tabBar.minX + $0.minX, y: tile.tabBar.minY, width: $0.width, height: tile.tabBar.height)
            }
            closeRects[tile.stackID] = view.tabRects.map {
                let cr = view.closeRect(for: $0)
                return CGRect(x: tile.tabBar.minX + cr.minX, y: tile.tabBar.minY + cr.minY, width: cr.width, height: cr.height)
            }
            tabWindows[tile.stackID] = tile.windows
            if !panel.isVisible { panel.orderFrontRegardless() }
            panel.display()
        }
        for (id, panel) in panels where !seen.contains(id) {
            panel.orderOut(nil)
            panels[id] = nil
        }
    }

    /// The window whose tab is under `p` (AX coordinates), if `p` is inside a tab bar,
    /// and whether `p` is inside that tab's close button.
    func tab(at p: CGPoint) -> (stack: ObjectIdentifier, window: WindowID, onClose: Bool)? {
        for (stack, rects) in tabRects {
            guard let frame = frames[stack], frame.contains(p), let windows = tabWindows[stack] else { continue }
            if let i = rects.firstIndex(where: { $0.contains(p) }), i < windows.count {
                let onClose = closeRects[stack]?[i].contains(p) ?? false
                return (stack, windows[i], onClose)
            }
        }
        return nil
    }

    /// Tab rect (AX coordinates) of a window, if it is shown in a tab bar.
    func anchor(for w: WindowID) -> CGRect? {
        for (stack, windows) in tabWindows {
            if let i = windows.firstIndex(of: w), let rects = tabRects[stack], i < rects.count { return rects[i] }
        }
        return nil
    }

    func setHovered(_ w: WindowID?, closeHovered: Bool = false) {
        for panel in panels.values {
            let shows = w.map(panel.tabView.items.map(\.id).contains) ?? false
            panel.tabView.hoveredID = shows ? w : nil
            panel.tabView.closeHovered = shows ? closeHovered : false
        }
    }

    func setFocused(_ focused: WindowID?) {
        for panel in panels.values {
            panel.tabView.isFocused = focused.map(panel.tabView.items.map(\.id).contains) ?? false
        }
    }

    /// Shows or hides the translucent drop-target preview overlay (`axRect` in AX coordinates).
    func showDropPreview(_ axRect: CGRect?) {
        guard let axRect else {
            dropPreview.orderOut(nil)
            return
        }
        let rect = CoordinateSpace.toAppKit(axRect)
        if dropPreview.frame != rect { dropPreview.setFrame(rect, display: true) }
        if !dropPreview.isVisible { dropPreview.orderFrontRegardless() }
    }

    /// Re-asserts z-order above the managed windows.
    func bringToFront() {
        for panel in panels.values where panel.isVisible { panel.orderFrontRegardless() }
    }

    func hideAll() {
        dropPreview.orderOut(nil)
        panels.values.forEach { $0.orderOut(nil) }
        panels.removeAll()
        frames.removeAll()
        tabRects.removeAll()
        closeRects.removeAll()
        tabWindows.removeAll()
    }

    private func makePanel(for id: ObjectIdentifier) -> TabBarPanel {
        let p = TabBarPanel()
        p.tabView.onTabClicked = { [weak self] w in self?.onTabClicked?(w) }
        p.tabView.onTabClosed = { [weak self] w in self?.onTabClosed?(w) }
        p.tabView.menuForTab = { [weak self] w in self?.menuForTab?(w) }
        p.tabView.onDragUpdated = { [weak self] w, pt in self?.onDragUpdated?(w, pt) }
        p.tabView.onDragEnded = { [weak self] w, pt in self?.onDragEnded?(w, pt) }
        panels[id] = p
        return p
    }
}

/// Translucent overlay showing where a dragged tab will land when dropped.
private final class DropPreviewPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        contentView = PreviewView()
    }

    private final class PreviewView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let accent = NSColor.controlAccentColor
            let r = bounds.insetBy(dx: 4, dy: 4)
            let path = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
            accent.withAlphaComponent(0.18).setFill()
            path.fill()
            path.lineWidth = 2
            accent.withAlphaComponent(0.75).setStroke()
            path.stroke()
        }
    }
}
