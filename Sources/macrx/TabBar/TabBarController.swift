import AppKit
import MacrxCore

/// Keeps one `TabBarPanel` per visible tile that has a tab bar.
@MainActor
final class TabBarController {
    var onTabClicked: ((WindowID) -> Void)?
    var fontSize: CGFloat = 12
    var widthMode: TabWidthMode = .fit

    private var panels: [ObjectIdentifier: TabBarPanel] = [:]

    /// Tab bar frames (AX coordinates) per stack, for pointer hit-testing.
    private(set) var frames: [ObjectIdentifier: CGRect] = [:]
    /// Per-stack tab rects (AX coordinates), in window order.
    private(set) var tabRects: [ObjectIdentifier: [CGRect]] = [:]
    private var tabWindows: [ObjectIdentifier: [WindowID]] = [:]

    func sync(tiles: [Tile], focused: WindowID?, item: (WindowID) -> TabItem) {
        var seen: Set<ObjectIdentifier> = []
        frames.removeAll(keepingCapacity: true)
        tabRects.removeAll(keepingCapacity: true)
        tabWindows.removeAll(keepingCapacity: true)
        for tile in tiles where tile.hasTabBar {
            seen.insert(tile.stackID)
            let panel = panels[tile.stackID] ?? makePanel(for: tile.stackID)
            let view = panel.tabView
            let rect = CoordinateSpace.toAppKit(tile.tabBar)
            if panel.frame != rect { panel.setFrame(rect, display: false) }
            view.fontSize = fontSize
            view.widthMode = widthMode
            view.items = tile.windows.map(item)
            view.topID = tile.top
            view.isFocused = focused.map(tile.windows.contains) ?? false
            view.layoutSubtreeIfNeeded()
            frames[tile.stackID] = tile.tabBar
            tabRects[tile.stackID] = view.tabRects.map {
                CGRect(x: tile.tabBar.minX + $0.minX, y: tile.tabBar.minY, width: $0.width, height: tile.tabBar.height)
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

    /// The window whose tab is under `p` (AX coordinates), if `p` is inside a tab bar.
    func tab(at p: CGPoint) -> (stack: ObjectIdentifier, window: WindowID)? {
        for (stack, rects) in tabRects {
            guard let frame = frames[stack], frame.contains(p), let windows = tabWindows[stack] else { continue }
            if let i = rects.firstIndex(where: { $0.contains(p) }), i < windows.count {
                return (stack, windows[i])
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

    func setHovered(_ w: WindowID?) {
        for panel in panels.values {
            let shows = w.map(panel.tabView.items.map(\.id).contains) ?? false
            panel.tabView.hoveredID = shows ? w : nil
        }
    }

    func setFocused(_ focused: WindowID?) {
        for panel in panels.values {
            panel.tabView.isFocused = focused.map(panel.tabView.items.map(\.id).contains) ?? false
        }
    }

    /// Re-asserts z-order above the managed windows.
    func bringToFront() {
        for panel in panels.values where panel.isVisible { panel.orderFrontRegardless() }
    }

    func hideAll() {
        panels.values.forEach { $0.orderOut(nil) }
        panels.removeAll()
        frames.removeAll()
        tabRects.removeAll()
        tabWindows.removeAll()
    }

    private func makePanel(for id: ObjectIdentifier) -> TabBarPanel {
        let p = TabBarPanel()
        p.tabView.onTabClicked = { [weak self] w in self?.onTabClicked?(w) }
        panels[id] = p
        return p
    }
}
